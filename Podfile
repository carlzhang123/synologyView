platform :ios, '15.0'
use_frameworks!

target 'SynologyView' do
  pod 'MobileVLCKit'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
end
