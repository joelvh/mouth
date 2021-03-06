require 'em-mongo'
require 'eventmachine'

module Mouth
  
  class SuckerConnection < EM::Connection
    attr_accessor :sucker
  
    def receive_data(data)
      Mouth.logger.debug "UDP packet: '#{data}'"
  
      sucker.store!(data)
    end
  end
  
  class Sucker
    
    # Host/Port to suck UDP packets on
    attr_accessor :host
    attr_accessor :port

    # Actual EM::Mongo connection
    attr_accessor :mongo
    
    # Info to connect to mongo
    attr_accessor :mongo_db_name
    attr_accessor :mongo_hostports
    
    # Accumulators of our data
    attr_accessor :counters
    attr_accessor :timers
    attr_accessor :gauges
    
    # Stats
    attr_accessor :udp_packets_received
    attr_accessor :mongo_flushes
    
    def initialize(options = {})
      self.host = options[:host] || "localhost"
      self.port = options[:port] || 8889
      self.mongo_db_name = options[:mongo_db_name] || "mouth"
      hostports = options[:mongo_hostports] || [["localhost", EM::Mongo::DEFAULT_PORT]]
      self.mongo_hostports = hostports.collect do |hp|
        if hp.is_a?(String)
          host, port = hp.split(":")
          [host, port || EM::Mongo::DEFAULT_PORT]
        else
          hp
        end
      end
      
      self.udp_packets_received = 0
      self.mongo_flushes = 0
      
      self.counters = {}
      self.timers = {}
      self.gauges = {}
    end
    
    def suck!
      EM.run do
        # Connect to mongo now
        self.mongo

        EM.open_datagram_socket host, port, SuckerConnection do |conn|
          conn.sucker = self
        end
        
        EM.add_periodic_timer(10) do
          Mouth.logger.info "Counters: #{self.counters.inspect}"
          Mouth.logger.info "Timers: #{self.timers.inspect}"
          Mouth.logger.info "Gauges: #{self.gauges.inspect}"
          self.flush!
          self.set_procline!
        end

        EM.next_tick do
          Mouth.logger.info "Mouth reactor started..."
          self.set_procline!
        end
      end
    end
    
    # counter: gorets:1|c
    # counter w/ sampling: gorets:1|c|@0.1
    # timer: glork:320|ms
    # gauge: gaugor:333|g
    def store!(data)
      key_value, command_sampling = data.to_s.split("|", 2)
      key, value = key_value.to_s.split(":")
      command, sampling = command_sampling.to_s.split("|")
      
      return unless key && value && command && key.length > 0 && value.length > 0 && command.length > 0
      
      key = Mouth.parse_key(key).join(".")
      value = value.to_f
      
      ts = Mouth.current_timestamp
      
      if command == "ms"
        self.timers[ts] ||= {}
        self.timers[ts][key] ||= []
        self.timers[ts][key] << value
      elsif command == "c"
        factor = 1.0
        if sampling
          factor = sampling.sub("@", "").to_f
          factor = (factor == 0.0 || factor > 1.0) ? 1.0 : 1.0 / factor
        end
        self.counters[ts] ||= {}
        self.counters[ts][key] ||= 0.0
        self.counters[ts][key] += value * factor
      elsif command == "g"
        self.gauges[ts] ||= {}
        self.gauges[ts][key] = value
      end
      
      self.udp_packets_received += 1
    end
    
    def flush!
      ts = Mouth.current_timestamp
      limit_ts = ts - 1
      mongo_docs = {}
      
      # We're going to construct mongo_docs which look like this:
      # "mycollections:234234": {  # NOTE: this timpstamp will be popped into .t = 234234
      #   c: {
      #     happenings: 37,
      #     affairs: 3
      #   },
      #   m: {
      #     occasions: {...}
      #   },
      #   g: {things: 3}
      # }
      
      self.counters.each do |cur_ts, counters_to_save|
        if cur_ts <= limit_ts
          counters_to_save.each do |counter_key, value|
            ns, sub_key = Mouth.parse_key(counter_key)
            mongo_key = "#{ns}:#{ts}"
            mongo_docs[mongo_key] ||= {}
            
            cur_mongo_doc = mongo_docs[mongo_key]
            cur_mongo_doc["c"] ||= {}
            cur_mongo_doc["c"][sub_key] = value
          end
          
          self.counters.delete(cur_ts)
        end
      end
      
      self.gauges.each do |cur_ts, gauges_to_save|
        if cur_ts <= limit_ts
          gauges_to_save.each do |gauge_key, value|
            ns, sub_key = Mouth.parse_key(gauge_key)
            mongo_key = "#{ns}:#{ts}"
            mongo_docs[mongo_key] ||= {}
            
            cur_mongo_doc = mongo_docs[mongo_key]
            cur_mongo_doc["g"] ||= {}
            cur_mongo_doc["g"][sub_key] = value
          end
          
          self.gauges.delete(cur_ts)
        end
      end
      
      self.timers.each do |cur_ts, timers_to_save|
        if cur_ts <= limit_ts
          timers_to_save.each do |timer_key, values|
            ns, sub_key = Mouth.parse_key(timer_key)
            mongo_key = "#{ns}:#{ts}"
            mongo_docs[mongo_key] ||= {}
            
            cur_mongo_doc = mongo_docs[mongo_key]
            cur_mongo_doc["m"] ||= {}
            cur_mongo_doc["m"][sub_key] = analyze_timer(values)
          end
          
          self.timers.delete(cur_ts)
        end
      end
      
      save_documents!(mongo_docs)
    end
    
    def save_documents!(mongo_docs)
      Mouth.logger.info "Saving Docs: #{mongo_docs.inspect}"
      
      mongo_docs.each do |key, doc|
        ns, ts = key.split(":")
        collection_name = Mouth.mongo_collection_name(ns)
        doc["t"] = ts.to_i
        
        self.mongo.collection(collection_name).insert(doc)
      end
      
      self.mongo_flushes += 1 if mongo_docs.any?
    end
    
    def mongo
      @mongo ||= begin
        if self.mongo_hostports.length == 1
          EM::Mongo::Connection.new(*self.mongo_hostports.first).db(self.mongo_db_name)
        else
          raise "Ability to connect to a replica set not implemented."
        end
      end
    end
    
    def set_procline!
      $0 = "mouth [started] [UDP Recv: #{self.udp_packets_received}] [Mongo saves: #{self.mongo_flushes}]"
    end
    
    private
    
    def analyze_timer(values)
      values.sort!
      
      count = values.length
      min = values[0]
      max = values[-1]
      mean = nil
      sum = 0.0
      median = median_for(values)
      stddev = 0.0
      
      values.each {|v| sum += v }
      mean = sum / count
      
      values.each do |v|
        devi = v - mean
        stddev += (devi * devi)
      end
      
      stddev = Math.sqrt(stddev / count)
      
      {
        "count" => count,
        "min" => min,
        "max" => max,
        "mean" => mean,
        "sum" => sum,
        "median" => median,
        "stddev" => stddev,
      }
    end
    
    def median_for(values)
      count = values.length
      middle = count / 2
      if count == 0
        return 0
      elsif count % 2 == 0
        return (values[middle] + values[middle - 1]).to_f / 2
      else
        return values[middle]
      end
    end
        
  end # class Sucker
end # module
