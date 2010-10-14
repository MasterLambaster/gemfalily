begin
  # Require the preresolved locked set of gems.
  require ::File.expand_path('./.bundle/environment', __FILE__)
rescue LoadError
  # Fallback on doing the resolve at runtime.
  require "rubygems"
  require "bundler"
  Bundler.setup
end
ROOT = ::File.expand_path(File.dirname(__FILE__))
require 'will_paginate'
require 'will_paginate/view_helpers/base'
require 'will_paginate/view_helpers/link_renderer'
require 'active_support'
require 'sinatra'
require 'mongo'
require 'graphviz'
require 'sinatra/cache'

WillPaginate::ViewHelpers::LinkRenderer.class_eval do
  protected
  def url(page)
    url = @template.request.url
    if page == 1
      # strip out page param and trailing ? if it exists
      url.gsub(/page=[0-9]+/, '').gsub(/\?$/, '')
    else
      if url =~ /page=[0-9]+/
        url.gsub(/page=[0-9]+/, "page=#{page}")
      else
        url + "#{(url =~ /\?/ ? "&" : "?")}page=#{page}"
      end
    end
  end
end

module Mongo
  mattr_accessor :connection, :collection

  def self.connect(connection)
    @@connection = Connection.new(connection[:host], connection[:port]).db(connection[:database])
    @@collection = @@connection.collection('gems')
  end
end

class RubyGem
  class GemVersions < Struct.new(:name, :version, :platform); end
  include Mongo

  attr :current_version
  def initialize(ruby_gem, version=nil)
    @gem = ruby_gem
    @current_version = version || @gem['version']
  end

  def current_version=(version)
    @current_version = version if version_info(version)
  end

  def name
    @gem['name']
  end

  def dependencies(version=current_version)
    runtime(version) + development(version)
  end

  def runtime(version=current_version)
    version_info(version)['deps']['runtime']
  end

  def development(version=current_version)
    version_info(version)['deps']['development']
  end

  def reversed_runtime
     @runtime ||= @@collection.find({'deps.deps.runtime.gem' => @gem['name']})
  end

  def reversed_development
     @development ||= @@collection.find({'deps.deps.development.gem' => @gem['name']})
  end

  def versions
    @version ||= @gem['deps'].inject([]) { |result, gem|
      result << GemVersions.new(@gem['name'], gem['version'], gem['platform'])
      result
    }
  end

  def dependent_version(dependency)
    version = Gem::Version.new(nil)
    dependency = Gem::Requirement.new(dependency)
    @gem['deps'].each do |gem_version|
      ver = Gem::Version.new(gem_version['version'])
      dependency.satisfied_by?(ver) or next
      if version < ver
        if dependency.prerelease?
          version = ver
        else
          version = ver unless ver.prerelease?
        end
      end
    end
    version
  end

  class << self
    def find_by_name(name, *args)
      gem = @@collection.find_one(:name => name, *args)
      self.new(gem) if gem
    end

    def paginate(query, page)
      page ||= 1
      count = Mongo.collection.find(query).count
      WillPaginate::Collection.create(page, 20, count) do |pager|
        result =Mongo.collection.find(query, {:limit => pager.per_page, :skip => pager.offset })
        pager.replace(result.to_a)
      end
    end

    def find_by_letter(letter, page)
      letter =~ /\A[A-Za-z]\z/ ? letter.upcase : 'A'
      paginate({:name => /^#{letter}/i}, page)
    end
  end

  protected

  def version_info(version = current_version)
    @gem['deps'].find {|v| v['version'] == version} #or
    #  raise Sinatra::NotFound, "#{version} was not found for #{@gem['name']}"
  end
end

class GraphBuilder
  attr_reader :graph

  def initialize(gem_name, version, options={})
    @options = {:virtual => false,
                :virtual_title => 'Root',
                :include_versions => false,
                :title => 'GemFamily'}.update(options)
    @graph = GraphViz.new(@options[:title], :type => :digraph)
    #Prevent multiple edges
    @graph["concentrate"] = true
    @graph['normalize'] = true
    #Edge label positioning
    @graph.edge['labeldistance'] = 3
    @graph.edge['labelangle'] = -30
    if @options[:virtual]
      node = @graph.add_node(@options[:virtual_title])
      gem_name.to_a.each do |gem|
        build_dependencies(gem.first, node, gem.last)
      end
    else
      gem = find_gem(gem_name, version)
      raise Sinatra::NotFound unless gem
      node = add_node(gem)
      gem.runtime.each do |dep|
        build_dependencies(dep['gem'], node, dep['version'])
      end
    end
  end

  private

  def build_dependencies(gem_name, parent_node=nil, parent_version=nil)
    #Find dependennt gem
    gem = find_gem(gem_name)
    return unless gem
    if parent_version && parent_node
      dep_version = gem.dependent_version(parent_version).to_s
      gem.current_version = dep_version
    end

    node = add_node(gem)
    add_edge(parent_node, node, parent_version)

    gem.runtime.each do |dep|
      build_dependencies(dep['gem'], node, dep['version'])
    end
  end

  def find_gem(name, version = nil)
    gem = RubyGem.find_by_name(name)
    gem.current_version = version if gem
    gem
  end

  def add_node(gem)
    node_label = gem.name
    if @options[:include_versions]
      node_label << '\n' << gem.current_version
    end
    @graph.add_node(node_label)
  end

  def add_edge(parent, child, version_label = nil)
    return unless parent || child
    edge_label = ''
    edge_label = version_label.to_s if version_label && @options[:include_versions]

    @graph.add_edge(parent, child, :headlabel => edge_label, :fontsize => 10)
  end
end

mime_type :pnd, 'image/png'
mime_type :svgz , 'image/svg+xml'
set :database, {:host => 'localhost', :port => Mongo::Connection::DEFAULT_PORT, :database => 'gemfamily'}
#Enabling cache
set :root, ROOT
set :public, File.join(ROOT, 'public')
set :cache_enabled, true
set :cache_output_dir, File.join(ROOT, 'public', 'cache')

before do
  Mongo.connect(settings.database)
end

not_found do
  haml :e404
end

helpers WillPaginate::ViewHelpers::Base
helpers do
  def base_url
    url = "http://#{request.host}"
    request.port == 80 ? url : url + ":#{request.port}"
  end

  def gem_url(gem_name, version = nil)
    gem_url = "/gems/#{gem_name}"
    gem_url << "/#{version}" if version
    File.join(base_url, gem_url)
  end

  def url_for(path)
    File.join(base_url, path[0] == '/'? path : "/#{path}")
  end

  def graph_url(name, version, format = "png")
    url_for("graph/#{name}-#{version}.#{format}")
  end
end

get '/' do
  haml :index
end

get '/search' do
  @gem = RubyGem.find_by_name(params[:q])
  @gem_list = RubyGem.paginate({:name => /#{params[:q]}/}, params[:page])
  @query = params[:q]
  haml :gems
end

get '/gems' do
  @gem_list = RubyGem.find_by_letter(params[:letter], params[:page])
  haml :gems
end

get '/bundle' do
    haml :bundle
end

get '/bundle/:id' do
  if File.exists?(File.join(settings.public, 'graphs', 'bundler', "#{params[:id]}.png"))
    haml :bundle_show
  end
end

post '/bundle' do
  if params[:gemlock_file] && (tmp_file = params[:gemlock_file][:tempfile]) && (name = params[:gemlock_file][:filename])
    content = tmp_file.read
  elsif params[:gemlock_content]
    content = params[:gemlock_content]
  end
  #content_type 'image/png'
  begin
    bundle = Bundler::LockfileParser.new(content)
  rescue
    @error = 'Gemfile.lock seems to be ivalid'
    return haml :bundle
  else
    #Collect bundler dependencies with their versions
    deps = bundle.dependencies.inject([]) do |res, dep|
      res << [dep.name, dep.requirements_list]
    end
    gb = GraphBuilder.new(deps, nil, :virtual => true, :include_versions => true, :virtual_title => params[:title])
    @img_id = BSON::ObjectID.new.to_s
    gb.graph.output(:png => File.join(settings.public, 'graphs', 'bundler', "#{@img_id}.png"))
    redirect "/bundle/#{@img_id}"
  end
end

get '/gems/:name/versions' do
  @gem = RubyGem.find_by_name(params[:name])
  raise Sinatra::NotFound unless @gem
  haml :versions
end

get %r{/graph/(([\w-]*)-([0-9]+(?:\.[0-9a-zA-Z]+)*)(?:-(v))?\.(svg|png|svgz))$} do
  filename, gem, version, version_info, format = params[:captures]
  path = File.join(settings.public, 'graphs', 'gem', filename)
  unless File.exists?(path)
    gb = GraphBuilder.new(gem, version, {:include_versions => !version_info.nil?})
    gb.graph.output(format.to_sym => path)
  end
  #Output file content
  headers({'Content-encoding' => 'gzip'}) if format == "svgz"
  content_type(format.to_sym)
  File.read(path)
end

get '/gems/:name/?*' do
  @gem = RubyGem.find_by_name(params[:name])
  raise Sinatra::NotFound unless @gem

  @gem.current_version = params[:splat].first if params[:splat]
  haml :show
end

post '/gem_update' do
  #TODO: This is not implemented
end

__END__

@@ bundle
%form{:method => :post, :enctype=> 'multipart/form-data'}
  %article
    %h1 Upload Gemfile.lock and get Gem Family Tree
    %p
      %label Title:
    %p
      %input{:type=> 'text', :name => 'title', :value => 'Root'}
    %p
      %label Gemfile<b>.lock</b> file:
    %p
      %input{:type => :file, :name => :gemlock_file}
    %p
      %input{:type=>:submit, :value => 'Build Gem Family'}
@@ bundle_show
%article
  %h1 Bundler tree
  .links
    %a{:href => "/graphs/bundler/#{params[:id]}.png"}
      %img{:src => "/graphs/bundler/#{params[:id]}.png"}

@@ e404
%head
  %h1 Opps, page is not found

@@ gems
%article
  -if @query
    %h1 Search results for "#{@query}"
  -else
    %h1 All gems
  -if @gem
    %h2 Exact match
    %a{:href => gem_url(@gem.name)}= @gem.name
  -if @query
    %h2 Search results
  %section{:id=>'gem-list'}
    %ul
    - @gem_list.each do |gem|
      %li
        %a{:href => gem_url(gem['name'])}= gem['name']
    != will_paginate(@gem_list)
@@ index
%article
  %h1 Gem Family
  %p The place where you can get information about gem dependencies, study their family tree and even build own graphs form your Gemfile.
  %p Any designer help is appreciated to improve site look and feel.
@@ layout
%html
  %head
    %link{:rel=>"stylesheet",:href=>"/main.css",:type=>"text/css",:media=>"screen"}
    %title Gem Family
  %body
    %header{:id=>'masterhead'}
      #headwrap
        %h1 Gem Family
        %nav{:id=>'menu'}
          %ul
            %li
              %a{:href => url_for('')} Home
              %a{:href => url_for('gems')} Gem List
              %a{:href => url_for('bundle')} Bundle parser
          #search
            %form{:action => url_for('search')}
              %input{:type=>'text', :class=>'input', :name=>'q'}
              %input{:type=>'submit', :class=>'button', :value=>'Go'}
    %section{:id=>'main'}
      = yield
    %footer
      %p
        %small &copy; 2010 | created by <a href="http://twitter.com/MasterLambaster">@MasterLambaster</a>
    /
      Coming soon, give me some time to cleanup the code
      %a#ribbon(href='http://github.com/MasterLambaster/gemfamily')
        %img{ :alt => 'fork me on Github', :src => 'http://s3.amazonaws.com/github/ribbons/forkme_right_white_ffffff.png' }
    :javascript
      var gaJsHost = (("https:" == document.location.protocol) ? "https://ssl." : "http://www.");
      document.write(unescape("%3Cscript src='" + gaJsHost + "google-analytics.com/ga.js' type='text/javascript'%3E%3C/script%3E"));
    :javascript
      var pageTracker = _gat._getTracker("UA-11771766-2");
      pageTracker._trackPageview();

@@ show
%article
  %h1 <strong>#{@gem.name}</strong> <small>(#{@gem.current_version})</small>
  %a{:href=>"http://rubygems.org/gems/#{@gem.name}"} Gem info on Rubygems.org
  %aside
    %h2 Versions
    .links
      %ul
        - @gem.versions.reverse.slice(0..5).each do |ver|
          %li
            %a{:href => gem_url(@gem.name, ver.version)}= ver.version
        -if @gem.versions.count > 5
          %li
            %a{:href => "/gems/#{@gem.name}/versions"} Show all versions(#{@gem.versions.count})
- if @gem.runtime.count>0 || @gem.development.count>0
  %article
    %h1 <strong>#{@gem.name}</strong> Dependencies
    - if @gem.runtime.count>0
      %aside
        %h2 Runtime Dependencies(#{@gem.runtime.count})
        .links
          - @gem.runtime.each do |dep|
            %a{:href=>gem_url(dep['gem'])}
              = dep['gem']
              = dep['version']
    - if @gem.development.count>0
      %aside
        %h2 Development Dependencies(#{@gem.development.count})
        .links
          - @gem.development.each do |dep|
            %a{:href=>gem_url(dep['gem'])}
              = dep['gem']
              = dep['version']
- if @gem.reversed_runtime.count>0 || @gem.reversed_development.count>0
  %article
    %h1 Gems dependent on <strong>#{@gem.name}</strong>
    -if @gem.reversed_runtime.count>0
      %aside
        %h3 Runtime Dependencies(#{@gem.reversed_runtime.count})
        .links
          - @gem.reversed_runtime.each do |dep|
            %a{:href=>gem_url(dep['name'])}= dep['name']
    -if @gem.reversed_development.count>0
      %aside
        %h2 Development Dependencies(#{@gem.reversed_development.count})
        .links
          - @gem.reversed_development.each do |dep|
            %a{:href=>gem_url(dep['name'])}= dep['name']

%article
  %h1 <strong>#{@gem.name}</strong> Family Tree
  .links
    %a{:href=>graph_url(@gem.name, @gem.current_version)}
      %img{:src => graph_url(@gem.name, @gem.current_version)}
    - %w{png svg svgz}.each do |format|
      %a{:href => graph_url(@gem.name, @gem.current_version, format)}= format

@@ versions
%article
  %h1 All <strong>#{@gem.name}</strong> versions
  .links
    %ul
      - @gem.versions.reverse.each do |ver|
        %li
          %a{:href => gem_url(@gem.name, ver.version)}
            = ver.version
            - if ver.platform
              (#{ver.platform})

