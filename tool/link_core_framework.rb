#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
target = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target missing')

sources = target.source_build_phase
runner = project.main_group.find_subpath('Runner') || project.main_group.new_group('Runner', 'Runner')
(Dir['ios/Runner/*.swift'] + Dir['ios/Runner/*.m']).sort.each do |path|
  reference = runner.files.find { |f| f.path == File.basename(path) } || runner.new_reference(File.basename(path))
  sources.add_file_reference(reference, true) unless sources.files_references.include?(reference)
end

group = project.main_group.find_subpath('Frameworks') || project.main_group.new_group('Frameworks', 'Frameworks')
reference = group.files.find { |f| f.path == 'Core.xcframework' } || group.new_file('Core.xcframework')
target.frameworks_build_phase.add_file_reference(reference, true) unless target.frameworks_build_phase.files_references.include?(reference)

target.build_configurations.each do |config|
  settings = config.build_settings
  search = Array(settings['FRAMEWORK_SEARCH_PATHS'] || '$(inherited)')
  search << '$(PROJECT_DIR)/Frameworks' unless search.include?('$(PROJECT_DIR)/Frameworks')
  settings['FRAMEWORK_SEARCH_PATHS'] = search

  flags = Array(settings['OTHER_LDFLAGS'] || '$(inherited)')
  %w[-ObjC -lc++ -lsqlite3 -lz -lresolv].each { |flag| flags << flag unless flags.include?(flag) }
  settings['OTHER_LDFLAGS'] = flags

  if File.exist?('ios/Runner/Runner-Bridging-Header.h')
    settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Runner/Runner-Bridging-Header.h'
  end
end

project.save
puts "linked #{reference.path} and #{Dir['ios/Runner/*.swift'].length} Swift sources into Runner"
