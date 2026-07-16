Gem::Specification.new do |spec|
  spec.name          = "kdc"
  spec.version       = "0.1.0"
  spec.authors       = ["kdc2tiff"]
  spec.summary       = "Pure Ruby KDC file parser and converter (port of LibRaw logic)"
  spec.description   = "Parse Kodak KDC raw files from DC120/DC50 cameras and convert to 16-bit TIFF"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*.rb", "bin/*"]
  spec.executables   = ["kdc"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.0"

  spec.add_dependency "pure_jpeg", "~> 0.3"
  spec.add_dependency "rainbow", "~> 3.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake"
end
