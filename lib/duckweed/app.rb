require 'duckweed'
require 'duckweed/geckoboard_methods'
require 'duckweed/notify_hoptoad'
require 'duckweed/utility_methods'
require 'duckweed/graphite_methods'
require 'duckweed/graphite_http_methods'
require 'json'
require 'sinatra'
require 'hoptoad_notifier'

module Duckweed
  # Ignore the most recent bucket. This prevents histograms whose
  # rightmost data points droop unexpectedly.
  DEFAULT_OFFSET = 1

  MINUTE = 60
  HOUR   = MINUTE * 60
  DAY    = HOUR * 24
  YEAR   = DAY * 365

  class App < Sinatra::Base
    include GeckoboardMethods
    include UtilityMethods
    include GraphiteMethods
    include GraphiteHTTPMethods
    extend NotifyHoptoad

    # routes accessible without authorization:
    AUTH_WHITELIST = ['/health']

    configure do |app|
      GraphiteMethods.setup(app)
      GraphiteHTTPMethods.setup(app)
    end

    before do
      unless AUTH_WHITELIST.include?(request.path_info) || authorized?
        halt 403, 'Forbidden'
      end
    end

    # TODO: remove legacy route
    get '/legacy_check/:event' do
      require_threshold!
      check_threshold(params[:event], :minutes, 60)
    end

    # TODO: remove legacy route
    get '/legacy_check/:event/:granularity/:quantity' do
      require_threshold!
      check_request_limits!
      check_threshold(params[:event], params[:granularity].to_sym, params[:quantity].to_i)
    end

    get '/check/:event' do
      require_threshold!
      graphite_check_threshold(params[:event], graphite_params(params))
    end

    get '/check/:event/:granularity/:quantity' do
      require_threshold!
      check_request_limits!
      graphite_check_threshold(params[:event], graphite_params(params))
    end

    # TODO: remove legacy route
    get '/legacy_count/:event' do
      # default to last hour with minute-granularity
      count = count_for(params[:event], :minutes, 60).to_s
      format_count(count, params)
    end

    # TODO: remove legacy route
    get '/legacy_count/:event/:granularity/:quantity' do
      check_request_limits!
      count = count_for(params[:event], params[:granularity].to_sym, params[:quantity].to_i).to_s
      format_count(count, params)
    end

    get '/count/:event' do
      # default to last hour with minute-granularity
      count = graphite_integral(params[:event], graphite_params(params))
      format_count(count, params)
    end

    get '/count/:event/:granularity/:quantity' do
      check_request_limits!
      count = graphite_integral(params[:event], graphite_params(params))
      format_count(count, params)
    end

    # Useful for testing Hoptoad notifications
    get '/exception' do
      raise RuntimeError, "wheeeeeeeeeeeeeeeeeeee"
    end

    get '/health' do
      'OK'
    end

    # TODO: remove legacy route
    get '/legacy_histogram/:event' do
      histogram(params[:event], :minutes, 60)
    end

    # TODO: remove legacy route
    get '/legacy_histogram/:event/:granularity/:quantity' do
      check_request_limits!
      histogram(params[:event], params[:granularity].to_sym, params[:quantity].to_i)
    end

    get '/histogram/:event' do
      graphite_histogram(params[:event], :minutes, 60)
    end

    get '/histogram/:event/:granularity/:quantity' do
      check_request_limits!
      graphite_histogram(params[:event], params[:granularity].to_sym, params[:quantity].to_i)
    end

    # TODO: remove legacy route
    get '/legacy_histogram-delta/:event_a/:event_b' do
      histogram_delta(params[:event_a], params[:event_b], :minutes, 60)
    end

    # TODO: remove legacy route
    get '/legacy_histogram-delta/:event_a/:event_b/:granularity/:quantity' do
      check_request_limits!
      histogram_delta(params[:event_a], params[:event_b],
                      params[:granularity].to_sym, params[:quantity].to_i)
    end

    get '/histogram-delta/:event_a/:event_b' do
      graphite_histogram_delta(params[:event_a], params[:event_b], :minutes, 60)
    end

    get '/histogram-delta/:event_a/:event_b/:granularity/:quantity' do
      check_request_limits!
      graphite_histogram_delta(params[:event_a], params[:event_b],
                      params[:granularity].to_sym, params[:quantity].to_i)
    end

    # TODO: implement for graphite (currently unused)
    get '/accumulate/:event' do
      accumulate(params[:event], :minutes, 60)
    end

    # TODO: implement for graphite (currently unused)
    get '/accumulate/:event/:granularity/:quantity' do
      check_request_limits!
      accumulate(params[:event], params[:granularity].to_sym, params[:quantity].to_i)
    end

    # TODO: implement for graphite (currently unused)
    get '/group/:group' do
      group_members(params[:group]).to_json
    end

    # TODO: implement for graphite (currently unused)
    get '/group_count/:group' do
      count = group_members(params[:group]).map do |event|
        count_for(event, :minutes, 60)
      end.reduce(0, &:+).to_s
      format_count(count, params)
    end

    # TODO: implement for graphite (currently unused)
    get '/group_count/:group/:granularity/:quantity' do
      count = group_members(params[:group]).map do |event|
        count_for(event, params[:granularity].to_sym, params[:quantity].to_i)
      end.reduce(0, &:+).to_s
      format_count(count, params)
    end

    # TODO: implement for graphite (currently unused)
    # Only using post to get around request-length limitations w/get
    post '/multicount' do
      events = params[:events] || []
      events += group_members(params[:group]) if params[:group]

      granularity = (params['granularity'] || :minutes).to_sym
      quantity = params[:quantity] || 60

      check_request_limits!(granularity, quantity)

      events.inject({}) do |response, event|
        response.merge(event => count_for(event, granularity, quantity))
      end.to_json
    end

    post '/track/:event' do
      unless authorized?('w')
        halt 403, "Forbidden"
      end
      add_to_groups(params[:group], params[:event]) if params[:group]
      increment_counters_for(params[:event])
      'OK'
    end

    private

    def redis
      Duckweed.redis
    end

    def graphite_params(params)
      granularity = params[:granularity] ? params[:granularity] : 'minutes'
      quantity = params[:quantity] ? params[:quantity] : 60
      {
        :from  => "-#{quantity}#{granularity}",
      }
    end

    def authorized?(permission='r')
      Token.authorized?(auth_token_via_params ||
        auth_token_via_http_basic_auth, permission)
    end

    def auth_token_via_params
      params[:auth_token]
    end

    def auth_token_via_http_basic_auth
      auth = Rack::Auth::Basic::Request.new(request.env)
      auth.provided? && auth.basic? && auth.credentials.first
    end

    def format_count(count, params)
      if params[:format] == "geckoboard_json"
        geckoboard_jsonify_for_counts(count)
      else
        count
      end
    end

    # The little bit of extra time on each bucket is so that we have a
    # round number of complete buckets available for querying. For
    # example, by having a day and a minute as the expiry time for the
    # :minutes bucket, we let the user query for a full day of
    # minute-resolution data. Were we to use just a day, then a query
    # for a day's worth of data would be met with a 413, since the
    # default offset is 1 (to ignore the current, half-baked bucket),
    # and so the user would have to instead ask for 23 hours and 59
    # minutes' worth of data, causing them to wonder just what kind of
    # idiots wrote this app.
    #
    # There's no technical reason for the extra time; it's purely
    # aesthetic.
    INTERVAL = {
      :minutes => {
        :bucket_size  => MINUTE,
        :expiry       => DAY * 2 + MINUTE,
        :time_format  => '%I:%M%p'    # 10:11AM
      },
      :hours => {
        :bucket_size  => HOUR,
        :expiry       => DAY * 28 + HOUR,
        :time_format  => '%a %I%p'    # Sun 10AM
      },
      :days => {
        :bucket_size  => DAY,
        :expiry       => YEAR * 5 + DAY,
        :time_format  => '%b %d %Y'   # Jan 21 2011
      }
    }

    MAX_EXPIRY = INTERVAL.values.collect{|i| i[:expiry]}.max

    # don't allow requests that would place an unreasonable load on the server,
    # or for which we won't have data anyway
    def check_request_limits!(granularity = params[:granularity],
        quantity = params[:quantity],
        offset = params[:offset])
      granularity = granularity.to_sym
      quantity = quantity.to_i
      offset = (offset || DEFAULT_OFFSET).to_i

      if !(interval = INTERVAL[granularity])
        halt 400, 'Bad Request'
      elsif ((quantity + offset) * interval[:bucket_size]) > interval[:expiry]
        halt 413, 'Request Entity Too Large'
      end
    end

    def increment_counters_for(event)
      counters = {}
      INTERVAL.keys.each do |granularity|
        key = key_for(event, granularity)
        if has_bucket_for?(granularity)
          counters[granularity] =
            if params[:quantity]
              redis.incrby(key, params[:quantity].to_i)
            else
              redis.incr(key)
            end
          redis.expire(key, INTERVAL[granularity][:expiry])
        end
      end

      update_graphite(params[:event], counters)

      counters
    end

    def key_for(event, granularity)
      "duckweed:#{event}:#{bucket_with_granularity(granularity)}"
    end

    def bucket_with_granularity(granularity)
      "#{granularity}:#{bucket_index(granularity)}"
    end

    def bucket_index(granularity)
      timestamp / INTERVAL[granularity][:bucket_size]
    end

    def timestamp
      (params[:timestamp] || Time.now).to_i
    end

    def count_for(event, granularity, quantity)
      keys = keys_for(event, granularity.to_sym, quantity)
      redis.mget(*keys).inject(0) { |memo, obj| memo + obj.to_i }
    end

    def keys_for(event, granularity, quantity)
      count = quantity ? quantity.to_i : INTERVAL[granularity][:expiry]
      bucket_indices(granularity, count).map do |idx|
        "duckweed:#{event}:#{granularity}:#{idx}"
      end
    end

    def key_for_group(group)
      "duckweed-group:#{group}"
    end

    def add_to_groups(groups, event)
      Array(groups).each do |group|
        key = key_for_group(group)
        redis.sadd(key, event)
        # unused groups expire with their events
        redis.expire(key, MAX_EXPIRY)
      end
    end

    def group_members(group)
      keys = Array(group).map {|g| key_for_group(g) }
      redis.sunion(*keys)
    end

    def max_buckets(granularity)
      INTERVAL[granularity][:expiry] / INTERVAL[granularity][:bucket_size]
    end

    def bucket_indices(granularity, count)
      bucket_idx = bucket_index(granularity) -
        count -
        (params[:offset] || DEFAULT_OFFSET).to_i
      Array.new(count) do |i|
        bucket_idx += 1
      end
    end

    def require_threshold!
      threshold = params[:threshold]
      if threshold.nil? || threshold.empty?
        halt 400, 'ERROR: Must provide threshold'
      end
    end

    def check_threshold(event, granularity, quantity)
      threshold = params[:threshold]
      count = count_for(event, granularity, quantity)
      if count.to_i >= threshold.to_i
        "GOOD: #{count}"
      else
        "BAD: #{count} < #{threshold}"
      end
    end

    def graphite_check_threshold(event, graphite_params)
      threshold = params[:threshold]
      count = graphite_integral(event, graphite_params(params))
      if count.to_i >= threshold.to_i
        "GOOD: #{count}"
      else
        "BAD: #{count} < #{threshold}"
      end
    end

    def has_bucket_for?(granularity)
      first_available_bucket_time = Time.now.to_i - INTERVAL[granularity][:expiry]
      first_available_bucket_time < timestamp
    end

    def histogram(event, granularity, quantity)
      values, times = values_and_times_for(granularity, event, quantity)
      geckoboard_jsonify_for_chart(values, times)
    end

    def graphite_histogram(event, granularity, quantity)
      values = graphite_summarize(event, granularity,
                                  graphite_params(params))
      times  = times_for(granularity, quantity)
      geckoboard_jsonify_for_chart(values, times)
    end

    def graphite_histogram_delta(event_a, event_b, granularity, quantity)
      values = graphite_summarize_diff(event_a, event_b, granularity,
                                       graphite_params(params))
      times = times_for(granularity, quantity)
      geckoboard_jsonify_for_chart(values, times)
    end

    def histogram_delta(event_a, event_b, granularity, quantity)
      values_a, times_a = values_and_times_for(granularity, event_a, quantity)
      values_b, times_b = values_and_times_for(granularity, event_b, quantity)
      values = values_a.zip(values_b).map {|a, b| a - b}
      geckoboard_jsonify_for_chart(values, times_a)
    end

    def accumulate(event, granularity, quantity)
      # Fetch all the unexpired data we have, so that we can start counting from "1"
      values, times = values_and_times_for(granularity, event, max_buckets(granularity))

      # massage the values to be cumulative
      values = values.inject([]) do |result, element|
        result << result.last.to_i + element
      end

      # return only the quantity we asked for
      geckoboard_jsonify_for_chart(values[-quantity.to_i..-1], times[-quantity.to_i..-1])
    end

    def times_for(granularity, quantity)
      ending    = Time.now.to_i
      beginning = ending.to_i - INTERVAL[granularity][:bucket_size] * quantity.to_i
      middle    = (beginning + ending) / 2
      [beginning, middle, ending].map do |time|
        Time.at(time).strftime(INTERVAL[granularity][:time_format])
      end
    end

    def values_and_times_for(granularity, event, quantity)
      keys        = keys_for(event, granularity, quantity)
      values      = redis.mget(*keys).map(&:to_i)
      times       = times_for(granularity, quantity)
      [values, times]
    end
  end
end
