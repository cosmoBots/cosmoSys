gem 'libxml-ruby', '>= 6.0'

rspreadsheet_path = ENV['RSPREADSHEET_PATH'].to_s
if rspreadsheet_path.empty?
  gem 'rspreadsheet',
      git: 'https://github.com/cosmoBots/rspreadsheet.git',
      ref: 'c01d413abc728db9d62aa1bebe776f548ee69999',
      require: false
else
  gem 'rspreadsheet', path: rspreadsheet_path, require: false
end
