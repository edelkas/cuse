require 'net/http'
require 'socket'

# NOTES (for vid/tut):
# - Levels are cached, so switch tab / search / wait
# - If program exits badly, reopen and reclose to repatch library

EXPORT     = false # Export raw HTTP requests and responses, for debugging
EXPORT_REQ = false
EXPORT_DBG = false
EXPORT_RES = false
INTERCEPT  = true  # Whether to intercept or forward userlevel requests
ALL_TABS   = false # Intercept from all tabs (as opposed to only Search)
TEST       = true  # Use test outte (at localhost)
PAGING     = true  # Whether to allow scrolling in-game to change the page

$port_npp      = 8124 # Port used to comunicate with the game
$port_outte    = 8125 # Port used to comunicate with outte
$target        = "https://dojo.nplusplus.ninja"
$proxy         = "http://localhost:#{$port_npp}".ljust($target.length, "\x00")
$outte         = TEST ? "127.0.0.1" : "45.32.150.168"
$last_req      = "rzcglfrg" # Last request string input by user
$timeout_npp   = 0.25 # Time to wait for the game (local, so quick)
$timeout_outte = 5    # Time to wait for outte (not local, so long)
$socket        = nil  # Permanent socket with the game
$res           = nil  # Store outte's response, to forward to the game
$count         = 1    # Proxied request counter
$root_page     = 0    # Page that'll show at the top in-game
$page          = 0    # Current page (different if we've scrolled down)

def clear
  print "\r".ljust(80, ' ') + "\r"
end

def log(line)
  method, path, protocol = line.split  
  puts "#{"%-4s" % method} #{path.split('?')[0].split('/')[-1]}"
end

def _pack(n, size)
  n.to_s(16).rjust(2 * size, "0").scan(/../).reverse.map{ |b|
    [b].pack('H*')[0]
  }.join.force_encoding("ascii-8bit")
end

def _unpack(bytes)
  if bytes.is_a?(Array) then bytes = bytes.join end
  bytes.unpack('H*')[0].scan(/../).reverse.join.to_i(16)
end

def find_lib
  paths = {
    'windows' => "",
    'linux'   => "#{Dir.home}/.steam/steam/steamapps/common/N++/lib64/libnpp.so"
  }
  sys = 'linux'
  paths[sys]
end

def patch
  IO.binwrite(find_lib, IO.binread(find_lib).gsub($target, $proxy))
  puts 'Patched'
end

def depatch
  IO.binwrite(find_lib, IO.binread(find_lib).gsub($proxy, $target))
  puts 'Depatched'
end

def read(client, npp)
  req = ""
  begin
    if !npp
      req << client.read
    else
      req << client.read_nonblock(16 * 1024) while true
    end
  rescue Errno::EAGAIN
    if IO.select([client], nil, nil, npp ? $timeout_npp : $timeout_outte)
      retry
    else
      return nil if req.size == 0
    end
  rescue
  end
  req
end

def clear_headers(http)
  http.delete('accept-encoding')
  http.delete('accept')
  http.delete('user-agent')
  http.delete('host')
  http.delete('content-length')
  http.delete('content-type')
  http
end

def empty_query(pars)
  cat     = pars.key?('search') ? 36 : (pars['qt'].to_i || 10)
  mode    = pars['mode'].to_i || 0
  header  = Time.now.strftime("%Y-%m-%d-%H:%M") # Date of query  (16B)
  header += _pack(0,    4)                      # Map count      ( 4B)
  header += _pack(0,    4)                      # Query page     ( 4B)
  header += _pack(0,    4)                      # Type           ( 4B)
  header += _pack(cat,  4)                      # Query category ( 4B)
  header += _pack(mode, 4)                      # Game mode      ( 4B)
  header += _pack(5,    4)                      # Cache duration ( 4B)
  header += _pack(500,  4)                      # Max page size  ( 4B)
  header += _pack(0,    4)                      # ?              ( 4B)
  header
end

def parse_params(path)
  path.split('?').last.split('&').map{ |p| p.split('=') }.to_h
end

# TODO: Add more integrity checks (map count, block lengths, etc)
def validate_res(res, pars)
  return empty_query(pars) if !res.is_a?(String)
  return empty_query(pars) if res.size < 48
  return empty_query(pars) if _unpack(res[24...28]) != 0
  return empty_query(pars) if _unpack(res[32...36]) != pars['mode'].to_i
  cat = pars.key?('search') ? 36 : (pars['qt'] || 10).to_i
  page = (pars['page'] || 0).to_i
  res[20...24] = _pack(page, 4)
  res[28...32] = _pack(cat,  4)
  res
end

def intercept(req)
  return forward(req) if !INTERCEPT
  pars = parse_params(req.split("\n")[0].split[1])
  if PAGING
    $page = $root_page + pars['page'].to_i
    call
  end
  body = validate_res($res, pars)
  status = "HTTP/1.1 200 OK\r\n"
  headers = {
    'content-type'   => 'application/octet-stream',
    'content-length' => body.size.to_s,
    'connection'     => 'keep-alive'
  }.map{ |k, v| "#{k}: #{v}\r\n" }.join
  "#{status}#{headers}\r\n#{body}"
end

def forward(req)
  # Build proxied request
  method, path, protocol = req.split("\r\n")[0].split
  uri = URI.parse($target + path)
  case method.upcase
  when 'GET'
    reqNew = Net::HTTP::Get.new(uri)
  when 'POST'
    reqNew = Net::HTTP::Post.new(uri)
  else
    raise "Unknown HTTP method requested by N++"
  end
  reqNew = clear_headers(reqNew)
  req.split("\r\n\r\n")[0].split("\r\n")[1..-1].map{ |h| h.split(": ") }.each{ |h|
    reqNew[h[0]] = h[1]
  }
  reqNew['host'] = $target[8..-1]
  reqNew.body = req.split("\r\n\r\n")[1..-1].join("\r\n\r\n")
  # Execute proxied request
  res = ""
  f = File.open("dbg_#{$count}", "wb") if EXPORT || EXPORT_DBG
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 2
  http.set_debug_output(f) if EXPORT || EXPORT_DBG
  res = http.start{ |http| http.request(reqNew) }
  f.close if EXPORT || EXPORT_DBG
  # Build proxied response
  status = "HTTP/1.1 #{res.code} #{res.msg}\r\n"
  headers = res.to_hash.map{ |k, v| "#{k}: #{v[0]}\r\n" }.join
  "#{status}#{headers}\r\n#{res.body}"
end

def startup
  patch
  $socket = TCPServer.new($port_npp)
  puts 'Started'
end

def loop
  client = $socket.accept
  req = client.gets
  log(req)
  method, path, protocol = req.split
  req << read(client, true).to_s
  IO.binwrite("req_#{$count}", req) if EXPORT || EXPORT_REQ
  query = path.split('?')[0].split('/')[-1]
  if method == 'GET' && (query == 'levels' || ALL_TABS && query == 'query_levels')
    res = intercept(req)
  else
    res = forward(req)
  end
  IO.binwrite("res_#{$count}", res) if EXPORT || EXPORT_RES
  client.write(res)
  client.close
  $count += 1
rescue => e
  puts "Unknown error."
  puts e
  puts e.backtrace.join("\n")
  client.close if client.is_a?(BasicSocket)
end

def shutdown
  clear
  depatch
  puts "Stopped"
  exit
end

def call(req = $last_req)
  Socket.tcp($outte, $port_outte) do |conn|
    conn.write("page #{$page + 1} #{req}")
    conn.close_write
    $res = read(conn, false)
    $last_req = req
    conn.close
    puts($res.nil? ? "Connection to outte timed out." : "Received #{$res.size} bytes from outte.")
  end
rescue
  puts "Unable to connect to outte."
end

trap 'INT' do shutdown end
startup
threads = {}
threads[:server] = Thread.new{ loop while true }
threads[:input]  = Thread.new{ call(STDIN.gets.chomp) while true }
threads[:server].join
