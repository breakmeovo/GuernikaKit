Pod::Spec.new do |s|
  s.name             = 'GuernikaKitAi'
  s.version          = '1.0.0'
  s.summary          = 'GuernikaKitAi.'
  s.description      = <<-DESC
                       GuernikaKitAi.
                       DESC
  s.homepage         = 'https://github.com/GuernikaCore/GuernikaKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Your Name' => 'your_email@example.com' }
  s.source           = { :git => 'https://github.com/GuernikaCore/GuernikaKit.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/**/*'
  s.dependency 'RandomGeneratorAi', '~> 1.0.0'
  s.dependency 'SchedulersAi', '~> 1.0.0'
end
