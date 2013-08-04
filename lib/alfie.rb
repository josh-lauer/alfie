#
# This creates an ActiveRecord class method called lazy_cache, which stores the block passed to it
# as a proc, and defines a class method which, when invoked, calls the proc, then caches and returns
# the result. Calling "expire_lazy_cache" on the model expires the cache for the key/method passed to
# it if one is provided, otherwise it expires the cache for all lazy_cache methods on the model on 
# which it was invoked.
#
# Example use:
# User.lazy_cache(:oliver){ User.where(email: "oliver@uwithus.com").first }
#

#
# TODO
# - implement configuration in a block style to be invoked in an intializer
# I.E.->
#    Alfie.configure do
#      config.ttl = 1.day
#      config.engine = :memcached
#    end
# - implement global TTL default and TTL per-key (with non-expiring being the default)
# - implement optional memcahched backing, defaulting to local class instance variables 
# - implement column cache expiry
# - implement levels of whinyness, from "returns nil on misses" to "raises exception on misses"
# - implement a setting to allow cacheing 'misses', i.e., if the user calls the lazy_column_accessor
#   and a record with that value doesn't exist, cache the result of the query or not

module Alfie

  # these are only included when a class method with an initializer exists
  module InstanceMethods
  end

  # these are defined for all ActiveRecord::Base descendants
  module ClassMethods

    def lazy_cache(method_name, options = {}, &block)
      raise "a block is required" if !block_given?
      raise "the method #{self.name}.#{method_name.inspect} is already defined, use another name" if respond_to?(method_name)
      __alfie_init(options)
      @alfie_procs[method_name.to_sym] = block
      __meta_def(method_name) { __alfie_fetch(method_name) }
    end

    def expire_lazy_cache(key = nil)
      if key
        @alfie_store[:cache][key].delete
      else
        @alfie_store[:cache] = {}
      end
    end

    def cache_by_column(column_name, options = {})
      __alfie_init(options)
      method_name = options[:as] || column_name
      raise "the method #{self.name}.#{method_name.inspect} is already defined, define another name using \":as => :method_name\"" if respond_to?(method_name)
      @alfie_columns[column_name.to_sym] ||= {}
      __meta_def(method_name) { |key| __alfie_column_fetch(column_name.to_sym, key.to_sym) }
    end

    def alfie_settings
      __alfie_settings
    end

    private

    # returns the class singleton, the instance of class Class
    # defaults to the metaclass of self, but can optionally
    # return the metaclass of any class specified with the ':context'
    # named argument
    def __metaclass(context: self)
      class << context; self; end
    end

    # evaluates block in the metaclass of context
    def __meta_eval(context: self, &block)
      __metaclass(context: context).instance_eval &block
    end

    # add a method to the metaclass of context
    def __meta_def(method_name, context: self, &block)
      __meta_eval(context: context) { define_method method_name, &block }
    end

    # defines an instance method on context
    def __class_def(method_name, context: self, &block)
      context.class_eval { define_method method_name, &block }
    end

    def __alfie_default_settings
      { 
        :ttl => nil, # falsy or integer
        :cache_method => :local # false, :local, :memcached
      }
    end

    def __alfie_settings
      __alfie_default_settings.merge(Rails.configuration.alfie_setting)
    end

    # # initializes necessary class instance vars
    # def __alfie_init(options = {})
    #   @alfie_store ||= {cache: {}, procs: {}}
    #   @alfie_columns ||= {}
    #   @alfie_settings ||= {}.merge(options)
    #   include Alfie::InstanceMethods
    # end

    # initializes necessary class instance vars
    def __alfie_init(options = {})
      __meta_eval(context: ActiveRecord::Base){@alfie_store ||= ActiveSupport::Cache::MemoryStore.new}
      @alfie_procs ||= {}
      @alfie_columns ||= {}
      @alfie_settings ||= {}.merge(options)
      include Alfie::InstanceMethods
    end

    # def __alfie_fetch(key)
    #   if @alfie_store[:cache].has_key?(key)
    #     @alfie_store[:cache][key]
    #   else
    #     @alfie_store[:cache][key] = @alfie_store[:procs][key].call
    #   end
    # end

    # def __alfie_store_proc(key, p)
    #   @alfie_procs[key] = p
    # end

    # def __alfie_fetch_proc(key)
    #   @alfie_store.read("alfie/procs/#{key}")
    # end

    def __alfie_fetch(key)
      if @alfie_store.exist?("#{self.name}/#{key}")
        @alfie_store.fetch("#{self.name}/#{key}")
      elsif @alfie_procs.has_key?(key)
        result = @alfie_procs[key].call
        @alfie_store.write("#{self.name}/#{key}", result)
        result
      else
        # complete cache miss
        nil
      end
    end

    def __alfie_column_fetch(column, key)
      if @alfie_columns[column].has_key?(key)
        @alfie_columns[column][key]
      else
        query_result = where(column => key.to_s).first
        @alfie_columns[column][key] = query_result if query_result
      end
    end

  end

end

ActiveRecord::Base.send(:extend, Alfie::ClassMethods)