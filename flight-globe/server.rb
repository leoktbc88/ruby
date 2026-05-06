#!/usr/bin/env ruby
# Tiny static file server (no gems — WEBrick was removed from default gems in Ruby 3.0).
# Usage: ruby server.rb [port]
require 'socket'

PORT = (ARGV[0] || ENV['PORT'] || 8000).to_i
ROOT = __dir__

MIME = {
  '.html' => 'text/html; charset=utf-8',
  '.css'  => 'text/css; charset=utf-8',
  '.js'   => 'text/javascript; charset=utf-8',
  '.mjs'  => 'text/javascript; charset=utf-8',
  '.json' => 'application/json; charset=utf-8',
  '.svg'  => 'image/svg+xml',
  '.png'  => 'image/png',
  '.jpg'  => 'image/jpeg',
  '.ico'  => 'image/x-icon',
}
MIME.default = 'application/octet-stream'

def safe_path(req_path)
  path = req_path.split('?', 2).first
  path = '/index.html' if path == '/' || path.empty?
  path = '/' + path unless path.start_with?('/')
  full = File.expand_path(File.join(ROOT, path))
  return nil unless full.start_with?(ROOT + File::SEPARATOR) || full == ROOT
  full
end

def respond(client, status, body, headers = {})
  reason = { 200 => 'OK', 404 => 'Not Found', 400 => 'Bad Request', 405 => 'Method Not Allowed' }[status] || 'OK'
  hdr = {
    'Content-Type'   => 'text/plain; charset=utf-8',
    'Content-Length' => body.bytesize.to_s,
    'Cache-Control'  => 'no-cache',
    'Connection'     => 'close',
  }.merge(headers)
  client.write("HTTP/1.1 #{status} #{reason}\r\n")
  hdr.each { |k, v| client.write("#{k}: #{v}\r\n") }
  client.write("\r\n")
  client.write(body)
end

def handle(client)
  req = client.gets
  return unless req
  method, path, _ = req.split(' ', 3)
  # Drain headers.
  while (line = client.gets) && line != "\r\n" && line != "\n"; end
  return respond(client, 405, 'Method Not Allowed') unless method == 'GET'

  full = safe_path(path)
  return respond(client, 400, 'Bad path') unless full
  return respond(client, 404, 'Not Found') unless File.file?(full)

  body = File.binread(full)
  ctype = MIME[File.extname(full)]
  respond(client, 200, body, 'Content-Type' => ctype)
rescue Errno::EPIPE, Errno::ECONNRESET
  # Client went away.
ensure
  client.close rescue nil
end

server = TCPServer.new('0.0.0.0', PORT)
puts "Flight Routes Globe → http://localhost:#{PORT}/  (Ctrl-C to stop)"
trap('INT')  { puts; exit }
trap('TERM') { exit }

loop do
  Thread.new(server.accept) { |c| handle(c) }
end
