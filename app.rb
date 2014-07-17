#!/usr/bin/env ruby

require 'sinatra'
require "sinatra/reloader" if development?
require "sinatra/json"
require 'socket'
require 'thread'
require 'json'
require 'color'
require 'colorize'

$config = JSON.parse(File.read('config.json'))

set :bind, $config['bind'] if $config.has_key? 'bind'
set :port, $config['port'] if $config.has_key? 'port'

$worker_queue ||= Queue.new
$worker ||= Thread.new do
  while true
    request, queue = $worker_queue.pop
    response = nil
    begin
      if request == :settings
        # noop
      elsif request == :sync
        puts "SYNC".cyan
        Region.sync
      elsif request.is_a?(Hash)
        Region.apply request
      elsif request.is_a?(Array)
        Region.execute request
      else
        raise "invalid request: #{request.inspect}"
      end
      response = Region.to_hash
    rescue Exception => e
      puts [e.message, *e.backtrace].map { |line| "[#{Thread.current}] #{line}".red }
      response = {:ok => false}
    end
    queue << response if queue
  end
end

$syncer ||= Thread.new do
  while true
    sleep 30
    $worker_queue << :sync
  end
end

before do
  @data = JSON.parse(request.body.read) if request.post?
end

get '/' do
  erb :index
end

get '/settings' do
  json sync_request(:settings)
end

post '/settings' do
  validate_settings @data or halt 400
  json sync_request(@data)
end

post '/settings/:region' do
  @data = { params[:region] => @data }
  validate_settings @data or halt 400
  json sync_request(@data)
end

post '/settings/:region/:zone' do
  @data = { params[:region] => { params[:zone] => @data } }
  validate_settings @data or halt 400
  json sync_request(@data)
end

post '/sequence' do
  validate_sequence @data or halt 400
  json sync_request(@data)
end

helpers do
  def sync_request(data)
    response = Queue.new
    $worker_queue << [data, response]
    response = response.pop
    halt 400 if response.is_a?(Hash) and response.has_key?(:ok) and !response[:ok]
    response
  end

  def validate_sequence(data)
    data.is_a?(Array) and data.all? { |step|
      validate_step step
    }
  end

  def validate_step(step)
    if step.is_a?(Hash)
      validate_settings step
    else
      validate_command step
    end
  end

  def validate_command(step)
    if step.is_a?(Hash)
      validate_settings step
    else
      validate_command step
    end
  end

  def validate_command(command)
    return false unless command.is_a?(Array) and command.size > 0
    command, *args = command
    case command
    when 'sleep'
      true
    when 'reset'
      true
    else
      false
    end
  end

  def validate_settings(data)
    data.each_pair.all? { |key, value|
      $config['regions'].has_key?(key) and
      validate_region(key, value)
    }
  end

  def validate_region(region, data)
    data.each_pair.all? { |key, value|
      $config['regions'][region]['zones'].has_key?(key) and
      validate_zone(region, key, value)
    }
  end

  def validate_zone(region, zone, data)
    data.each_pair.all? { |key, value|
      validate_setting region, zone, key, value
    }
  end

  def validate_setting(region, zone, key, value)
    case key
    when 'name'
      true
    when 'power'
      true
    when 'color'
      true
    when 'brightness'
      true
    else
      false
    end
  end
end

class Region
  def self.all
    $config['regions'].keys.map { |name| find name }
  end

  def self.find(name)
    new name, $config['regions'][name]
  end

  def self.to_hash
    Hash[all.map { |region| [region.name, region.to_hash] }]
  end

  def self.apply(settings)
    settings.each_pair do |region, zones|
      region = find(region)
      zones.each_pair do |zone, settings|
        region.zone(zone).apply settings
      end
    end
  end

  def self.execute(sequence)
    old_settings = to_hash
    sequence.each do |step|
      puts "#{step.inspect}".green
      if step.is_a?(Hash)
        apply step
      elsif step.is_a?(Array)
        command, *args = step
        case command
        when 'sleep'
          sleep args.first.to_f
        when 'reset'
          apply old_settings
        else
          raise "invalid command step: #{step.inspect}"
        end
      else
        raise "invalid step type: #{step.inspect}"
      end
    end
  end

  def self.sync
    all.each { |region| region.sync }
  end

  attr_reader :name, :bridge

  def initialize(name, config)
    @name = name
    @config = config
    @bridge = Bridge.find_or_create(name, config)

    # Precreate all the Zone objects so that #to_hash can return them.
    @zones = {}
    config['zones'].keys.each { |id| zone id }
  end

  def zone(id)
    @zones[id] ||= Zone.new(self, id, @config['zones'][id])
  end

  def to_hash
    Hash[@zones.map { |id, zone| [id, zone.to_hash] }]
  end

  def sync
    @bridge.sync
  end
end

class Zone
  attr_reader :region, :id, :name

  def initialize(region, id, config = nil)
    @region = region
    @id = id
    @config = config || {}
    @name = @config['name'] || id.to_s
  end

  def apply(settings)
    @region.bridge.apply @id, settings
  end

  def to_hash
    @region.bridge.zone(@id).to_hash.merge({ 'name' => name })
  end
end

class Bridge
  def self.find_or_create(name, config)
    @@instances ||= {}
    @@instances[name] ||= driver(config).new(config)
  end

  def self.driver(config)
    constants.map { |c| const_get(c) }.find { |c|
      c.is_a?(Class) and c < self and c.handles?(config)
    } or raise "no driver found to handle #{config.inspect}"
  end

  def sync
    # noop in base class
  end
end

class Bridge::LimitlessLed < Bridge
  def self.handles?(config)
    config['type'] == 'limitlessled-rgbw'
  end

  def initialize(config)
    host = config['host'] || 'localhost'
    port = config['port'].to_i || 8899
    @socket = UDPSocket.new
    @socket.connect(host, port)
    @zones = [AllZones.new(self, 0)]
    @zones += (1..4).map { |zone| Zone.new(self, zone) }

    # Record the last time a command was sent to the bridge.  This is used to
    # guarantee a 100ms delay between all packages because I have the
    # impression that the bridge (or light bulbs) may behave better with this.
    # It could also help in guessing whether the bulbs might be out of sync
    # with the state that we have and periodically apply all settings again.
    @last_send = Time.now
  end

  def apply(zone, settings)
    self.zone(zone).apply settings
  end

  def zone(zone)
    @zones[zone.to_i]
  end

  def brightness(zone, brightness)
    unless brightness.is_a?(Fixnum) and brightness.between?(2, 27)
      raise "invalid brightness: #{brightness.inspect}"
    end
    puts "ZONE #{zone} BRIGHTNESS #{brightness}".red
    power_on zone
    sleep 0.1
    send 0x4e, brightness, 0x55
  end

  def white(zone)
    puts "ZONE #{zone} WHITE".red
    power_on zone
    sleep 0.1
    send zone == 0 ? 0xc2 : 0xc5 + ((zone-1)*2), 0x00, 0x55
  end

  def color(zone, color)
    unless color.is_a?(Fixnum) and color.between?(0, 255)
      raise "invalid color: #{color.inspect}"
    end
    puts "ZONE #{zone} COLOR #{color}".red
    power_on zone
    sleep 0.1
    send 0x40, color, 0x55
  end

  def power_on(zone)
    puts "ZONE #{zone} ON".red
    send zone == 0 ? 0x42 : 0x45 + ((zone-1)*2), 0x00, 0x55
  end

  def power_off(zone)
    puts "ZONE #{zone} OFF".red
    send zone == 0 ? 0x41 : 0x46 + ((zone-1)*2), 0x00, 0x55
  end

  def sync
    @zones[1..4].each { |zone| zone.sync }
  end

  private
  
  def send(*bytes)
    if (delay = 0.1 - (Time.now - @last_send)) > 0
      puts "(waiting #{delay * 1000} ms)"
      sleep delay
    end
    #puts "UDP: #{bytes.map { |byte| "%02X" % byte}.join ' '}".red
    @socket.send bytes.pack('C*'), 0
    @last_send = Time.now
  end

  class Zone
    WHITE = Color::RGB.by_name("white")
    BLACK = Color::RGB.by_name("black")

    attr_reader :power, :color, :brightness

    def initialize(bridge, zone)
      @bridge = bridge
      @zone = zone
      @color_code = nil
    end

    def to_hash
      { 'power' => power, 'color' => color, 'brightness' => brightness }
    end

    def power=(value)
      @power = !!value unless value.nil?
    end

    def color=(value)
      if value.nil?
        # ignore
      else
        color = Color::RGB.by_name(value.to_s) { |s| Color::RGB.from_html s }
        if color == BLACK
          raise "can't set the color to black; set power=false instead?"
        elsif color == WHITE
          @color_code = nil
        else
          @color_code = color_code(color)
        end
        @color = color.html
      end
    end

    def color_code(color)
      ((-(color.to_hsl.hue - 240) % 360) / 360.0 * 255.0).to_i
    end
    private :color_code

    def brightness=(value)
      if value.nil?
        # ignore
      elsif value.is_a?(Fixnum) and value.between?(2, 27)
        @brightness = value
      else
        raise "invalid brightness: #{value.inspect}"
      end
    end

    def apply(settings)
      old_brightness, old_color, old_color_code, old_power = brightness, color, @color_code, power
      #puts "zone #{@zone} settings: #{settings.inspect}"
      begin
        self.brightness = settings['brightness'] if settings.has_key?('brightness')
        self.color      = settings['color']      if settings.has_key?('color')
        self.power      = settings['power']      if settings.has_key?('power')
      rescue Exception
        @brightness, @color, @color_code, @power = old_brightness, old_color, old_color_code, old_power
        raise
      end

      #puts "zone #{@zone} brightness: #{old_brightness.inspect} => #{@brightness.inspect}".green if old_brightness != @brightness
      #puts "zone #{@zone} color: #{old_color.inspect} => #{@color.inspect}".green if old_color != @color
      #puts "zone #{@zone} color code: #{old_color_code.inspect} => #{@color_code.inspect}".green if old_color_code != @color_code
      #puts "zone #{@zone} power: #{old_power.inspect} => #{@power.inspect}".green if old_power != @power

      if old_power != @power and !@power
        @bridge.power_off @zone
      elsif @power
        unless @color.nil?
          if old_color_code != @color_code or !old_power
            if @color_code.nil?
              @bridge.white @zone
            else
              @bridge.color @zone, @color_code
            end
            old_power = true
          end
        end

        unless @brightness.nil?
          if old_brightness != @brightness or !old_power or
              (old_color_code != @color_code and [old_color_code, @color_code].include?(nil))
            @bridge.brightness @zone, @brightness
            old_power = true
          end
        end

        if old_power != @power
          @bridge.power_on @zone
        end
      end
    end

    def sync
      if @power
        unless @color.nil?
          if @color_code.nil?
            @bridge.white @zone
          else
            @bridge.color @zone, @color_code
          end
        end
        @bridge.brightness @zone, @brightness unless @brightness.nil?
        @bridge.power_on @zone if @color.nil? and @brightness.nil?
      elsif !@power.nil?
        @bridge.power_off @zone
      end
    end
  end

  class AllZones < Zone
    def power
      values = (1..4).map { |zone| @bridge.zone(zone).power }
      values.uniq!
      values.size == 1 ? values[0] : nil
    end

    def color
      values = (1..4).map { |zone| @bridge.zone(zone).color }
      values.uniq!
      values.size == 1 ? values[0] : nil
    end

    def brightness
      values = (1..4).map { |zone| @bridge.zone(zone).brightness }
      values.uniq!
      values.size == 1 ? values[0] : nil
    end

    def power=(value)
      super
      (1..4).each { |zone| @bridge.zone(zone).power = value }
    end

    def color=(value)
      super
      (1..4).each { |zone| @bridge.zone(zone).color = value }
    end

    def brightness=(value)
      super
      (1..4).each { |zone| @bridge.zone(zone).brightness = value }
    end

    def apply(settings)
      @power = power
      @color = color
      @brightness = brightness
      super
    end

    def sync
      # don't sync the "all" zone, sync individual zones instead
    end
  end
end
