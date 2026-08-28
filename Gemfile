gem 'libxml-ruby', '>= 6.0'

rspreadsheet_path = ENV['RSPREADSHEET_PATH'].to_s
if rspreadsheet_path.empty?
  gem 'rspreadsheet',
      git: 'https://github.com/cosmoBots/rspreadsheet.git',
      ref: '3cf3031fc122306d09af7e503b66338c1b8ceb09',
      require: false
else
  gem 'rspreadsheet', path: rspreadsheet_path, require: false
end
