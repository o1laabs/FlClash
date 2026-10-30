Pod::Spec.new do |s|
  s.name                  = 'Core'
  s.version               = '1.0.0'
  s.summary               = 'FlClash mihomo core, built by gomobile.'
  s.homepage              = 'https://github.com/chen08209/FlClash'
  s.license               = { :type => 'GPL-3.0' }
  s.author                = { 'FlClash' => 'noreply@example.com' }
  s.source                = { :git => 'https://github.com/chen08209/FlClash.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.vendored_frameworks   = 'Frameworks/Core.xcframework'
  s.static_framework      = true
  s.libraries             = 'c++', 'sqlite3', 'z'
  s.user_target_xcconfig  = { 'OTHER_LDFLAGS' => '$(inherited) -ObjC' }
end
