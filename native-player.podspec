Pod::Spec.new do |s|
  s.name         = "native-player"
  s.version      = "1.0.0"
  s.summary      = "Custom Native Video Player"
  s.description  = "React Native native video player module"
  
  s.homepage     = "https://github.com/yourname/native-player"   # REQUIRED
  s.license      = { :type => "MIT" }                            # REQUIRED
  s.author       = { "Yash" => "narulayash994@gmail.com" }                # REQUIRED

  s.platform     = :ios, "13.0"
  s.source       = { :path => "." }                              # REQUIRED (LOCAL LIB)

  s.source_files = [
  "ios/**/*.{h,m,mm,swift}"
]
  
  s.requires_arc = true

  s.dependency "React-Core"
end