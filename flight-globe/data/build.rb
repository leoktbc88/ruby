#!/usr/bin/env ruby
# Convert OpenFlights .dat files into a compact JSON bundle the browser can load.
require 'csv'
require 'json'
require 'time'

DIR = File.expand_path(__dir__)

def parse(name)
  rows = CSV.read(File.join(DIR, name), liberal_parsing: true, encoding: 'UTF-8')
  rows.map { |r| r.map { |c| c == '\\N' ? nil : c } }
end

airports = {}
parse('airports.dat').each do |r|
  id, name, city, country, iata, icao, lat, lon, *_ = r
  next if iata.nil? || iata == '' || iata == '\\N'
  next if lat.nil? || lon.nil?
  airports[iata] = {
    name: name, city: city, country: country,
    iata: iata, icao: icao,
    lat: lat.to_f, lon: lon.to_f
  }
end

airlines = {}
parse('airlines.dat').each do |r|
  id, name, _alias, iata, icao, callsign, country, active = r
  next unless active == 'Y'
  next if (icao.nil? || icao == '') && (iata.nil? || iata == '')
  key = (icao && icao != '') ? icao : iata
  next if airlines.key?(key)
  airlines[key] = {
    name: name, iata: iata, icao: icao,
    callsign: callsign, country: country
  }
end

# Routes: airline IATA, airline ID, src IATA, src ID, dst IATA, dst ID, codeshare, stops, equipment
routes = []
seen = {}
parse('routes.dat').each do |r|
  air_iata, _air_id, src, _src_id, dst, _dst_id, _cs, stops, _eq = r
  next unless air_iata && src && dst
  next unless airports[src] && airports[dst]
  key = "#{air_iata}|#{src}|#{dst}"
  next if seen[key]
  seen[key] = true
  routes << [air_iata, src, dst, stops.to_i]
end

# Group routes by airline IATA, then resolve to airline ICAO when possible (for OpenSky callsign prefix matching).
airline_by_iata = {}
airlines.each do |_k, a|
  next if a[:iata].nil? || a[:iata] == ''
  airline_by_iata[a[:iata]] ||= a
end

routes_by_airline = {}
routes.each do |iata, src, dst, stops|
  routes_by_airline[iata] ||= []
  routes_by_airline[iata] << [src, dst, stops]
end

# Build the airline list we expose to the UI: only airlines that actually have routes,
# sorted by route count desc.
ui_airlines = routes_by_airline.map do |iata, rs|
  a = airline_by_iata[iata]
  next nil unless a
  {
    iata: iata,
    icao: a[:icao],
    name: a[:name],
    country: a[:country],
    callsign: a[:callsign],
    routeCount: rs.size
  }
end.compact.sort_by { |a| -a[:routeCount] }

# Compact airports map: only keep airports referenced by any route.
referenced = {}
routes.each { |_a, s, d, _| referenced[s] = true; referenced[d] = true }
ui_airports = referenced.keys.each_with_object({}) do |iata, h|
  ap = airports[iata]
  h[iata] = [ap[:lat].round(4), ap[:lon].round(4), ap[:name], ap[:city], ap[:country], ap[:icao]]
end

bundle = {
  generated: Time.now.utc.iso8601,
  airports: ui_airports,
  airlines: ui_airlines,
  routes: routes_by_airline
}

File.write(File.join(DIR, 'bundle.json'), JSON.generate(bundle))
puts "Airports: #{ui_airports.size}"
puts "Airlines (with routes): #{ui_airlines.size}"
puts "Routes: #{routes.size}"
puts "Bundle size: #{File.size(File.join(DIR, 'bundle.json'))} bytes"
