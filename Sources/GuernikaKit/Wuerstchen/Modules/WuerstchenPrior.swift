//
//  WuerstchenPrior.swift
//
//
//  Created by Guillermo Cique Fernández on 15/9/23.
//

import CoreML
import SchedulersAi
import Foundation

/// Prior noise prediction model for Wuerstchen
public class WuerstchenPrior {
    /// Model used to predict noise residuals given an input, diffusion time step, and conditional embedding
    ///
    /// It can be in the form of a single model or multiple stages
    let models: [ManagedMLModel]
    var reduceMemory: Bool = false
    var configuration: MLModelConfiguration {
        get { models[0].configuration }
        set {
            for model in models {
                model.configuration = newValue
            }
        }
    }
    
    public let converterVersion: String?
    public let attentionImplementation: AttentionImplementation
    
    /// The expected shape of the models timestemp input
    let timestepShape: [Int]
    let hiddenStatesShape: [Int]
    let latentSampleShape: [Int]
    public let sampleSize: CGSize
    public let minimumSize: CGSize
    public let maximumSize: CGSize
    public let hiddenSize: Int
    public let resolutionMultiple: Double

    /// Creates a U-Net noise prediction model
    ///
    /// - Parameters:
    ///   - url: Location of single U-Net  compiled Core ML model
    ///   - configuration: Configuration to be used when the model is loaded
    /// - Returns: U-net model that will lazily load its required resources when needed or requested
    public convenience init(modelAt url: URL, configuration: MLModelConfiguration? = nil) throws {
        try self.init(chunksAt: [url], configuration: configuration)
    }

    /// Creates a U-Net noise prediction model
    ///
    /// - Parameters:
    ///   - urls: Location of chunked U-Net via urls to each compiled chunk
    ///   - configuration: Configuration to be used when the model is loaded
    /// - Returns: U-net model that will lazily load its required resources when needed or requested
    public init(chunksAt urls: [URL], configuration: MLModelConfiguration? = nil) throws {
        let metadata = try CoreMLMetadata.metadataForModel(at: urls[0])
        timestepShape = metadata.inputSchema[name: "r"]!.shape
        hiddenStatesShape = metadata.inputSchema[name: "clip_text"]!.shape
        let sampleInput = metadata.inputSchema[name: "x"]!
        let sampleShape = sampleInput.shape
        latentSampleShape = sampleShape
        let resolutionMultiple = Double(metadata.userDefinedMetadata!["resolution_multiple"]!)!
        sampleSize = CGSize(
            width: Int(Double(sampleShape[3]) * resolutionMultiple),
            height: Int(Double(sampleShape[2]) * resolutionMultiple)
        )
        if sampleInput.hasShapeFlexibility {
            minimumSize = CGSize(
                width: Int(Double(sampleInput.shapeRange[3][0]) * resolutionMultiple),
                height: Int(Double(sampleInput.shapeRange[2][0]) * resolutionMultiple)
            )
            maximumSize = CGSize(
                width: Int(Double(sampleInput.shapeRange[3][1]) * resolutionMultiple),
                height: Int(Double(sampleInput.shapeRange[2][1]) * resolutionMultiple)
            )
        } else {
            minimumSize = sampleSize
            maximumSize = sampleSize
        }
        hiddenSize = Int(metadata.userDefinedMetadata!["hidden_size"]!)!
        self.resolutionMultiple = resolutionMultiple
        attentionImplementation = metadata.attentionImplementation
        converterVersion = metadata.userDefinedMetadata?["converter_version"]
        
        let configuration = configuration ?? attentionImplementation.preferredModelConfiguration
        self.models = urls.map { ManagedMLModel(modelAt: $0, configuration: configuration) }
    }

    /// Unload the underlying model to free up memory
    public func unloadResources() {
        for model in models {
            model.unloadResources()
        }
    }

    /// Batch prediction noise from latent samples
    ///
    /// - Parameters:
    ///   - latents: Batch of latent samples in an array
    ///   - timeStep: Current diffusion timestep
    ///   - hiddenStates: Hidden state to condition on
    /// - Returns: Array of predicted noise residuals
    func predictNoise(
        latents: [MLShapedArray<Float32>],
        timeStep: Double,
        clipTextPooled: MLShapedArray<Float32>,
        clipText: MLShapedArray<Float32>,
        clipImg: MLShapedArray<Float32>?
    ) throws -> [MLShapedArray<Float32>] {
        // Match time step batch dimension to the model / latent samples
        let t = MLShapedArray<Float32>(repeating: Float32(timeStep), shape: timestepShape)

        // Form batch input to model
        let inputs: [MLDictionaryFeatureProvider] = try latents.map {
            var dict: [String: Any] = [
                "x" : MLMultiArray($0),
                "r" : MLMultiArray(t),
                "clip_text_pooled": MLMultiArray(clipTextPooled),
                "clip_text": MLMultiArray(clipText),
//                "clip_img": MLMultiArray(clipImg)
            ]
            
            try models.first?.perform { model in
                let inputDescriptions = model.modelDescription.inputDescriptionsByName
                for input in inputDescriptions {
                    guard dict[input.key] == nil else { continue }
                    dict[input.key] = input.value.emptyValue
                }
            }
            return try MLDictionaryFeatureProvider(dictionary: dict)
        }
        let batch = MLArrayBatchProvider(array: inputs)

        // Make predictions
        let results = try predictions(from: batch)

        // Pull out the results in Float32 format
        let noise = (0..<results.count).map { i in
            let result = results.features(at: i)
            let outputName = result.featureNames.first!
            let outputNoise = result.featureValue(for: outputName)!.multiArrayValue!

            // To conform to this func return type make sure we return float32
            // Use the fact that the concatenating constructor for MLMultiArray
            // can do type conversion:
            let fp32Noise = MLMultiArray(
                concatenating: [outputNoise],
                axis: 0,
                dataType: .float32
            )
            return MLShapedArray<Float32>(fp32Noise)
        }

        return noise
    }

    private func predictions(from batch: MLBatchProvider) throws -> MLBatchProvider {
        var results = try models[0].perform { model in
            try model.predictions(fromBatch: batch)
        }

        if models.count == 1 {
            return results
        }
        
        if reduceMemory {
            models.first?.unloadResources()
        }
        
        // Manual pipeline batch prediction
        let inputs = batch.arrayOfFeatureValueDictionaries
        for stage in models.dropFirst() {
            // Combine the original inputs with the outputs of the last stage
            let next = try results.arrayOfFeatureValueDictionaries
                .enumerated()
                .map { index, dict in
                    let nextDict =  dict.merging(inputs[index]) { out, _ in out }
                    return try MLDictionaryFeatureProvider(dictionary: nextDict)
                }
            let nextBatch = MLArrayBatchProvider(array: next)

            // Predict
            results = try stage.perform { model in
                try model.predictions(fromBatch: nextBatch)
            }
            if reduceMemory {
                stage.unloadResources()
            }
        }

        return results
    }
}

