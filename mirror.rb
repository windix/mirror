require 'open-uri'
require 'uri'
require 'logger'
require 'digest/md5'
require 'cgi'
require 'thread'
require 'pp'

$logger = Logger.new(STDOUT)
$logger.level = Logger::DEBUG

class Site
  MAX_LEVELS = 10

  def initialize(source, destination)
    @destination = destination

    # setup assets hash and queue the initial asset
    @assets = {}
    @queue = Queue.new
    add_asset source, 1, true

    # start to download
    worker = process_queue
    worker.join

    $logger.debug "Queue is empty"

    $logger.debug "Update links"
    $logger.debug "Total assets: #{@assets.size}"
    update_links

    $logger.debug "Saving assets"
    save_assets

  end

  def add_asset(source, level, retrieve = false)
    unless @assets.has_key?(source)
      $logger.debug "Found #{source} Level ##{level}"
      asset = Asset.new(source, @destination, level)
      @assets[source] = asset
      
      if retrieve
        $logger.debug "Queued #{source}"
        
        #put into queue
        @queue.push asset
      end
    end
  end

  def process_queue
    Thread.new do
      while !@queue.empty?
        asset = @queue.pop
        begin
          $logger.debug "Downloading #{asset.source}"
          asset.download
          $logger.debug "Downloaded #{asset.source}"
        rescue
          $logger.error "Failed to download #{asset.source} - #{$!.message}"
          next
        end
        
        if asset.source != asset.original_source
          $logger.debug "Remove original source #{asset.original_source} from assets"
          @assets.delete(asset.original_source)
        end
        
        @assets[asset.source] = asset

        $logger.debug "Getting linked assets in #{asset.source}"
        process_links asset.get_links, asset.level + 1
      end
    end
  end
    
  def process_links(links, level)
    links.each do |link|
      if link.relation != :anchor && level < MAX_LEVELS
        add_asset link.source, level, true
      elsif
        add_asset link.source, level, false
      end
    end
  end

  def update_links
    @assets.each do |source, asset|
      if asset.retrieved
        $logger.debug "Updating links in #{source}"
        asset.update_links(@assets)
      end
    end
  end

  def save_assets
    @assets.each do |source, asset|
      if asset.retrieved
        $logger.debug "Saving #{source}"
        asset.save
      end
    end
  end

end

class Asset
  LINK_TYPES = {
    :image => [/<\s*(img[^\>]*src\s*=\s*["']?([^"'\s>]*))/im, [:location, :url]],
    :anchor => [/<\s*a[^\>]*(href\s*=\s*["']?([^"'\s>]*).*?>)(.*?)<\/a>/im, [:location, :url, :context]],
    :background => [/<\s*([body|table|th|tr|td][^\>]*background\s*=\s*["']?([^"'\s>]*))/im, [:location, :url]],
    :input => [/<\s*input[^\>]*(src\s*=\s*["']?([^"'\s>]*))/im, [:location, :url]],
    :css => [/<\s*link[^\>]*stylesheet[^\>]*[^\>]*(href\s*=\s*["']?([^"'\s>]*))/im, [:location, :url]],
    :cssinvert => [/<\s*link[^\>]*(href\s*=\s*["']?([^"'\s>]*))[^\>]*stylesheet\s*/im, [:location, :url]],
    :cssimport => [/(@\s*import\s*u*r*l*\s*["'\(]*\s?([^"'\s\);]*))/im, [:location, :url]],
    :cssurl => [/(url\(\s*["']?([^"'\s\)]+))/im, [:location, :url]],
    :javascript => [/<\s*script[^\>]*(src\s*=\s*["']?([^"'\s>]*))/im, [:location, :url]]
  }

  MIME_TYPES = {
    "text/css" => ".css",
    "image/gif" => ".gif",
    "text/html" => ".html",
    "image/jpeg" => ".jpg",
    "application/ecmascript" => ".js",
    "application/javascript" => ".js",
    "application/x-javascript" => ".js",
    "text/ecmascript" => ".js",
    "text/javascript" => ".js",
    "text/jscript" => ".js",
    "text/vbscript" => ".js",
    "image/png" => ".png",
    "text/plain" => ".txt",
  }

  attr_accessor :source, :original_source, :level, :filename, :retrieved

  def initialize(source, destination, level)
    @source = URI.escape(source)
    @original_source = @source
    @destination = destination
    @level = level
    @retrieved = false
  end

  def download
    unless @retrieved
      # grub the data
      open(@source) do |f|
        @content_type = f.content_type
        @source = URI.escape(f.base_uri.to_s)
        @data = f.read
      
        #$logger.debug "content_type = #{@content_type}"
        #$logger.debug "source = #{@source}"
      end
      
      @base = get_base
      #$logger.debug "base = #{@base}"

      @filename = get_filename
      #$logger.debug "filename = #{@filename}"
      
      @page_title = get_page_title
      #$logger.debug "page_title = #{@page_title}" 
      
      if @filename
        @destination = File.join(@destination, @filename)
        #$logger.debug "destination = #{@destination}"

        @retrieved = true
      end
    end
  end

  # get base url of the page
  def get_base
    if @data =~ /<\s*base[^\>]*href\s*=\s*[\""\']?([^\""\'\s>]*).*?>/im
      # if base tag is set in the page, use it
      
      base = ($1[-1] == ?/) ? $1 : $1 + "/"
      
      # remove base tag
      @data.gsub!($&, "")
    
      base
    else
      # if not, get it from source url

      uri = URI.parse(@source) 
      
      if uri.scheme == "http" 
        unless uri.path[-1] == ?/
          if pos = uri.path.rindex('/')
            uri.path = uri.path[0..pos]
          else
            uri.path = nil
          end
        end
        
        URI::HTTP.build([uri.userinfo, uri.host, uri.port, uri.path, nil, nil]).to_s
      else
        nil
      end
    end
  end

  def get_filename
    Digest::MD5.hexdigest(@source) + MIME_TYPES[@content_type] if MIME_TYPES.has_key?(@content_type)
  end
  
  def get_page_title
    $1 if MIME_TYPES[@content_type] == ".html" && @data =~ /<\s*title[^>]*>(.*?)<\/title>/im
  end

  def get_links
    @links = []
    
    if [".html", ".css"].include?(MIME_TYPES[@content_type])
      LINK_TYPES.each do |relation, details|
        re, match_names = *details
        
        @data.scan(re) do |matches|
          # build match data hash
          i = 0
          match_data = {}
          match_names.each { |k| match_data[k] = matches[i]; i += 1 }
          
          link = Link.new
          link.context = match_data[:context]  if match_data.has_key?(:context)
          link.location = match_data[:location]
          link.relation = relation
          
          link.original_source = match_data[:url]
          link.source = URI.join(@base, URI.escape(match_data[:url])).to_s
          
          @links << link
        end
      end
    end

    #@links.each do |link|
    #  $logger.debug "#{link.relation} | #{link.source}"
    #end

    @links
  end

  def update_links(assets)
    if @retrieved
      @links.each do |link|
        if assets.has_key?(link.source)
          if link.location && link.original_source && assets[link.source].filename
            s = link.location.gsub(link.original_source, assets[link.source].filename)
            @data.gsub!(link.location, s)
          end
        end
      end
    end
  end

  def save
    #TODO: exception handling
    if @retrieved
      File.open(@destination, 'w') do |f|
        f.write(@data) 
      end
      
      $logger.debug "Saved #{@source} as #{@destination}"
    end
  end

end

class Link
  attr_accessor :context, :location, :relation, :source, :original_source
end

#asset = Asset.new("http://192.168.22.12/", "output")
#asset = Asset.new("http://74.125.153.132/search?q=cache:KGmiR0Vr5OQJ:mofo.rubyforge.org/+ruby+url+parse&cd=2&hl=en&ct=clnk&client=safari", "output")
#asset = Asset.new("http://wikipedia.com", "output")
#asset = Asset.new("http://www.google.com", "output")
#asset.download

#site = Site.new("http://www.google.com", "output")
#site = Site.new("http://www.wikipedia.com", "output")
site = Site.new("http://74.125.153.132/search?q=cache:KGmiR0Vr5OQJ:mofo.rubyforge.org/+ruby+url+parse&cd=2&hl=en&ct=clnk&client=safari", "output")

__END__

TODO:
  1. add / remove trailing slash on URL: http://www.wikipedia.org/
