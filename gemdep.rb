require 'rubygems'
require 'pp'
require 'mongo'
include Mongo

def time(operation ="")
  start = Time.now
  yield
  pp "#{operation} finished in #{Time.now - start} secconds"
end
def parse_gem_spec(gems_specs, pre = false)
  gem_info = []
  #Store all version information
  gems_specs.each do |gem_spec|
    begin
      gem_deps = {:development => [], :runtime => []}
      gem_spec = gem_spec.first
      #Go thrugh each version dependency
      if gem_spec.dependencies.count > 0
        gem_spec.dependencies.each do |gem_dep|
          gem_dep = Gem::Dependency.new gem_dep.shift, gem_dep if gem_dep.is_a?(Array)
          dep_struct = { :gem => gem_dep.name,
                         :version => gem_dep.requirements_list}
          if [:development, :runtime].include? gem_dep.type
            gem_deps[gem_dep.type] << dep_struct
          else
            gem_deps[:runtime] << dep_struct
          end
        end
      end
      gem_info << {:version =>gem_spec.version.to_s, :deps  => gem_deps, :pre => pre, :platform => (gem_spec.platform.to_s == 'ruby'? nil : gem_spec.platform.to_s)}
    rescue
      pp "Exception!: #{$!}"
      redo unless $!.message =~ /Forbidden 403/ || $!.message =~ /marshal file format/
    end
  end
  gem_info
end

#Connect to the database
db = Connection.new.db('gemfamily')
col = db.collection('gems')
gems, source = nil

#Fetch the whole gem list
time "Fetching gem list" do
  gems = Gem::SpecFetcher.new.list
  #Use only one gem soure at the moment to prevent duplicates
  source = gems.keys.first
end
#Init fetcher
fetcher = Gem::SpecFetcher.new

start_flag = false

#Go through all gems
gems[source].each do |gem|
  #Get all gem versions information from source
  gem_versions,gem_info,gem_pre, current_version = nil
  failed = 0
  time "Get #{gem.first} information" do
    dep = Gem::Dependency.new(gem.first)
    #get both release and prerelease versions
    begin
      gem_versions = fetcher.fetch(dep, true, false, false)
      gem_pre = fetcher.fetch(dep, false, false, true)
    rescue
      pp "Something goes wrong"
      pp $!
      unless $!.message =~ /Forbidden 403/
        failed += 1
        pp "Retry ##{failed}"
        if failed > 5
          pp "Retrys does not help, skiping"
          failed = 0
          next 2
        else
          redo
        end
      else
        pp "Skiped #{gem.first} due to lack of version info"
        next 2
      end
    end
  end
  next if gem_versions.nil?
  #Parse gem info
  current_version = gem[1].to_s

  deps = parse_gem_spec(gem_versions) + parse_gem_spec(gem_pre, true)
  time "Saving record" do
    col.insert({:name => gem.first, :deps => deps, :version => current_version})
  end

  pp "Saved #{gem.first} gem"
end


