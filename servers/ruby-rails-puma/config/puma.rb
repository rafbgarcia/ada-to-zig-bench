environment ENV.fetch("RAILS_ENV", "production")
workers 0

min_threads = Integer(ENV.fetch("PUMA_MIN_THREADS", "0"), 10)
max_threads = Integer(ENV.fetch("PUMA_MAX_THREADS", "512"), 10)
threads min_threads, max_threads

persistent_timeout Integer(ENV.fetch("PUMA_PERSISTENT_TIMEOUT", "120"), 10)
first_data_timeout Integer(ENV.fetch("PUMA_FIRST_DATA_TIMEOUT", "120"), 10)
log_requests false
quiet

host = ENV.fetch("HOST", "127.0.0.1")
ports = (ENV["PORTS"] || ENV["PORT"] || "8080").split(",").filter_map do |item|
  item = item.strip
  next if item.empty?

  port = Integer(item, 10)
  raise ArgumentError, "invalid port #{item.inspect}" unless port.positive? && port < 65_536

  port
end.uniq

raise ArgumentError, "PORTS must contain at least one TCP port" if ports.empty?

ports.each do |port|
  bind "tcp://#{host}:#{port}"
end
