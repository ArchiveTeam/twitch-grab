local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")
local base64 = require("base64")
local html_entities = require("htmlEntities")

cjson.encode_empty_table_as_object(false)

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local novideos = {}
for s in string.gmatch(os.getenv("novideos"), "([0-9]+)") do
  novideos[s] = true
end

local retry_url = false
local is_initial_url = true

check_item_complete = function(item)
  if context["queries_queued"] then
    local count = 0
    for _ in pairs(context["queries_todo"]) do
      count = count + 1
    end
    if count > 0 then
      error("Not all GQL requests were made.")
    end
  end
  if item_type == "asset"
    or (
      (item_type == "video" or item_type == "novideo")
      and context["existence_checked"]
      and not context["exists"]
    ) then
    return nil
  end
  local matched = 0
  for _, pattern in pairs({
    "/" .. item_value .. "%-low%-0%.jpg$",
    "/" .. item_value .. "%-high%-0%.jpg$",
    "/" .. item_value .. "%-info%.json$"
  }) do
    for url, _ in pairs(downloaded) do
      if string.match(url, pattern) then
        matched = matched + 1
        break
      end
    end
  end
  if matched ~= 3 then
    error("Missing some URLs...")
  end
  local found_ts = false
  if item_type == "video" then
    for url, _ in pairs(downloaded) do
      if string.match(url, "%.ts$")
        or string.match(url, "%.ts%?") then
        found_ts = true
        break
      end
    end
    if not found_ts then
      error("Did not download any .ts URL.")
    end
  end
end

match_one = function(data, pattern)
  local result = nil
  for s in string.gmatch(data, pattern) do
    if result then
      error("Did not expect two matches.")
    end
    result = s
  end
  if not result then
    error("Did not find a match.")
  end
  return result
end

abort_item = function(item)
  abortgrab = true
  --killgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if string.match(url, "^https?://gql%.twitch%.tv/integrity") then
    return false
  end
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
--print("discovered", item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  if ids[url] then
    return nil
  end
  local value = nil
  local type_ = nil
  for pattern, name in pairs({
    ["^https?://[^/]*twitch%.tv/videos/([0-9]+)$"]="video",
    ["^https?://(assets?%.twitch%.tv/.+)$"]="asset",
    ["^https?://([^/]*twitchcdn%.net/.+)$"]="asset",
    ["^https?://([^/]*jtvnw%.net/.+)$"]="asset"
  }) do
    value = string.match(url, pattern)
    type_ = name
    if value then
      break
    end
  end
  if value and type_ then
    if novideos[value] then
      type_ = "novideo"
    end
    return {
      ["value"]=value,
      ["type"]=type_
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    local newcontext = {}
    new_item_type = found["type"]
    new_item_value = found["value"]
    new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_name ~= item_name then
      if item_name and not abortgrab then
        check_item_complete()
      end
      ids = {}
      context = newcontext
      context["existence_checked"] = false
      item_value = new_item_value
      item_type = new_item_type
      ids[string.lower(item_value)] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

percent_encode_url = function(url)
  temp = ""
  for c in string.gmatch(url, "(.)") do
    local b = string.byte(c)
    if b < 32 or b > 126 then
      c = string.format("%%%02X", b)
    end
    temp = temp .. c
  end
  return temp
end

allowed = function(url, parenturl)
  local noscheme = string.match(url, "^https?://(.*)$")

  if ids[url]
    or (noscheme and ids[string.lower(noscheme)]) then
    return true
  end

  if string.match(url, "%?lang=[a-z%-]+$") then
    return false
  end

  if string.match(url, "^https?://gql%.twitch%.tv/gql")
    or string.match(url, "^https?://gql%.twitch%.tv/integrity") then
    return true
  end

  local skip = false
  for pattern, type_ in pairs({
    ["^https?://(assets?%.twitch%.tv/.+)$"]="asset",
    ["^https?://([^/]*twitchcdn%.net/.+)$"]="asset",
    ["^https?://([^/]*jtvnw%.net/.+)$"]="asset"
  }) do
    match = string.match(url, pattern)
    if match then
      if type_ ~= "asset" then
        match = string.gsub(match, "/[aq]/", ":")
      end
      local new_item = type_ .. ":" .. match
      if new_item ~= item_name
        and not ids[string.lower(string.match(match, "([^:]+)$"))] then
        discover_item(discovered_items, new_item)
        if not string.match(match, "^assets%.twitch%.tv/assets/player%-core%-base%-") then
          skip = true
        end
      end
    end
  end
  if skip then
    return false
  end

  if string.match(url, "^https?://assets%.twitch%.tv/assets/player%-core%-base%-") then
    return true
  end

  for _, pattern in pairs({
    "([0-9]+)"
  }) do
    for s in string.gmatch(url, pattern) do
      if ids[string.lower(s)] then
        return true
      end
    end
  end

  if not string.match(url, "^https?://[^/]*twitch%.tv/")
    and not string.match(url, "^https?://[^/]*cloudfront%.net/") then
    discover_item(discovered_outlinks, string.match(percent_encode_url(url), "^([^%s]+)"))
    return false
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  --[[if allowed(url, parent["url"])
    and not processed(url)
    and string.match(url, "^https://")
    and not addedtolist[url] then
    addedtolist[url] = true
    return true
  end]]

  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

percent_encode_url = function(newurl)
  result = string.gsub(
    newurl, "(.)",
    function (s)
      local b = string.byte(s)
      if b < 32 or b > 126 then
        return string.format("%%%02X", b)
      end
      return s
    end
  )
  return result
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil
  local post_data = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    if not string.match(newurl, "^https?://") then
      return nil
    end
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0
      or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    local is_gql = string.match(url_, "^https?://gql%.twitch%.tv/gql")
      or string.match(url_, "^https?://gql%.twitch%.tv/integrity")
    if is_gql and not post_data then
      return false
    end
    if not processed(url_ .. tostring(post_data))
      and allowed(url_, origurl) then
      local headers = {}
      if is_gql then
        if post_data == nil then
          return nil
        end
        if not context["client_id"] then
          error("Client ID was not found.")
        end
        if not context["device_id"]
          or string.len(context["device_id"]) == 0 then
          error("Device ID was not found.")
        end
        headers["Client-Id"] = context["client_id"]
        headers["Referer"] = "https://twitch.tv/"
        headers["X-Device-Id"] = context["device_id"]
        --[[if string.match(url_, "tv/gql") then
          if not context["client_integrity"] then
            error("Client integrity was not found.")
          end
          headers["Client-Integrity"] = context["client_integrity"]
        end]]
      end
      if post_data then
        table.insert(urls, {
          url=url_,
          headers=headers,
          body_data=post_data,
          method="POST"
        })
      else
        table.insert(urls, {
          url=url_,
          headers=headers
        })
      end
      addedtolist[url_ .. tostring(post_data)] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function set_new_params(newurl, data)
    for param, value in pairs(data) do
      if value == nil then
        value = ""
      elseif type(value) == "string" then
        value = "=" .. value
      end
      if string.match(newurl, "[%?&]" .. param .. "[=&]") then
        newurl = string.gsub(newurl, "([%?&]" .. param .. ")=?[^%?&;]*", "%1" .. value)
      else
        if string.match(newurl, "%?") then
          newurl = newurl .. "&"
        else
          newurl = newurl .. "?"
        end
        newurl = newurl .. param .. value
      end
    end
    return newurl
  end

  local function increment_param(newurl, param, default, step)
    local value = string.match(newurl, "[%?&]" .. param .. "=([0-9]+)")
    if value then
      value = tonumber(value)
      value = value + step
      return set_new_params(newurl, {[param]=tostring(value)})
    else
      if default ~= nil then
        default = tostring(default)
      end
      return set_new_params(newurl, {[param]=default})
    end
  end

  local function get_count(data)
    local count = 0
    for _ in pairs(data) do
      count = count + 1
    end 
    return count
  end

  local function submit_post(newurl, data)
    post_data = data
    check(newurl)
    post_data = nil
  end

  local function json_to_params(params, data, key)
    if key == nil then
      key = ""
    end
    for k, v in pairs(data) do
      local newkey = key .. k
      if v ~= nil and v ~= cjson.empty_array and v ~= cjson.null then
        if type(v) == "table" then
          json_to_params(params, v, newkey .. "_")
        else
          v = urlparse.escape(tostring(v))
          if params[newkey] then
            error("Key found twice when constructing parameters.")
          end
          params[newkey] = v
        end
      end
    end
  end

  local function submit_graphql(data)
    local map = {
      ["###VIDEO_ID###"]=item_value,
      ["###USERNAME###"]=context["username"],
      ["###CHANNEL_ID###"]=context["channel_id"],
      ["###PLAYBACK_TOKEN###"]=context["playback_token"],
      ["###PLAYBACK_SIGNATURE###"]=context["playback_signature"]
    }
    for _, k in pairs({
      "###VIDEO_ID###", "###USERNAME###", "###CHANNEL_ID###",
      "###PLAYBACK_TOKEN###", "###PLAYBACK_SIGNATURE###"
    }) do
      if string.match(data, k) then
        if map[k] == nil then
          return false
        end
        data = string.gsub(data, k, map[k])
      end
    end
    data = string.gsub(data, "\"variables\":%[%]", "\"variables\":{}")
    if string.match(data, "###") then
      error("Not all variables filled in for GQL POST data.")
    end
    submit_post("https://gql.twitch.tv/gql", data)
    if not context["exists"] then
      return true
    end
    local decoded = cjson.decode(data)
    if decoded["operationName"] then
      decoded = {decoded}
    end
    local count = 0
    for _ in pairs(decoded) do
      count = count + 1
    end
    if count == 1 then
      decoded[1]["extensions"] = nil
      while true do
        local params = {}
        json_to_params(params, decoded[1])
        local keys = {}
        for k, _ in pairs(params) do
          table.insert(keys, k)
        end
        table.sort(keys)
        local newurl = "https://gql.twitch.tv/gql?"
        local i = 1
        while true do
          if keys[i] == nil then
            break
          end
          newurl = newurl .. keys[i] .. "=" .. params[keys[i]] .. "&"
          i = i + 1
        end
        newurl = string.match(newurl, "^(.+)[%?&]$")
        submit_post(newurl, data)
        if decoded[1]["query"] then
          decoded[1]["query"] = nil
        else
          break
        end
      end
    end
    return true
  end

  if string.match(url, "^https://[^%.]+%.cloudfront%.net/.+/storyboards/[^/]+$") then
    check(urlparse.absolute(url, item_value .. "-strip-0.jpg"))
    check(urlparse.absolute(url, item_value .. "-low-0.jpg"))
    check(urlparse.absolute(url, item_value .. "-high-0.jpg"))
    check(urlparse.absolute(url, item_value .. "-high-1.jpg"))
    check(urlparse.absolute(url, item_value .. "-high-2.jpg"))
    check(urlparse.absolute(url, item_value .. "-high-3.jpg"))
  end

  if allowed(url)
    and status_code < 300
    and item_type ~= "asset"
    and (
      not string.match(url, "^https?://[^/]*cloudfront%.net/")
      or string.match(url, "%.json")
      or string.match(url, "%.m3u8")
    ) then
    html = read_file(file)
    if string.match(url, "^https?://[^/]*twitch%.tv/videos/[0-9]+$")
      and not string.match(url, "^https?://m%.twitch%.tv/") then
      --context["client_id"] = string.match(html, 'clientId="([^"]+)"')
      context["client_id"] = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp" -- mobile client ID
      context["app_version"] = string.match(html, 'window%.__twilightBuildID="([0-9a-f%-]+)"')
      if not context["client_id"] then
        error("Could not find client ID.")
      end
      if not context["queries_queued"] then
        local graphql_queries = ""
        for line in string.gmatch(read_file("graphql_requests.txt"), "([^\n]+)") do
          if not string.match(line, "^#")
            and (
              not string.match(line, "PlaybackAccessToken_Template")
              or item_type == "video"
            ) then
            graphql_queries = graphql_queries .. line
          end
        end
        context["queries_todo"] = cjson.decode(graphql_queries)
        context["queries_queued"] = true
      end
      context["device_id"] = os.getenv("device_id")
      --submit_post("https://gql.twitch.tv/integrity", "")
      local player_core_base_num = match_one(html, "([0-9]+):\"player%-core%-base\"")
      local player_core_base_version = match_one(html, player_core_base_num .. ":\"([0-9a-f]+)\"")
      print("Found player-core-base number " .. player_core_base_num .. " and version " .. player_core_base_version .. ".")
      local player_core_base_url = "https://assets.twitch.tv/assets/player-core-base-" .. player_core_base_version .. ".js"
      check(player_core_base_url) -- correct, before ids[...]
      ids[player_core_base_url] = true
    end
    if string.match(url, "^https?://assets%.twitch%.tv/assets/player%-core%-base%-") then
      local version = match_one(html, "%.getVersion=function%(%){return\"([^\"]+)\"}")
      context["player_version"] = version
    end
    if string.match(url, "/storyboards/[0-9]+%-info%.json$") then
      for _, d in pairs(cjson.decode(html)) do
        for _, image in pairs(d["images"]) do
          check(urlparse.absolute(url, image))
        end
      end
      check(urlparse.absolute(url, item_value .. "-strip-0.jpg"))
    end
    --[[if url == "https://gql.twitch.tv/integrity"
      and (item_type == "video" or item_type == "novideo") then
      json = cjson.decode(html)
      context["client_integrity"] = json["token"]
    end]]
    if item_type == "video"
      and string.match(url, "^https?://usher%.ttvnw%.net/.-" .. item_value .. "%.m3u8") then
      local chosen_bitrate = nil
      local chosen_url = nil
      local chunked = nil
      for line in string.gmatch(html, "([^\n]+)") do
        if string.match(line, "^#") then
          local bitrate = string.match(line, "BANDWIDTH=([0-9]+)")
          if bitrate then
            bitrate = tonumber(bitrate)
            if not chosen_bitrate or bitrate > chosen_bitrate then
              chosen_bitrate = bitrate
              chosen_url = nil
            end
          end
          if string.match(line, "VIDEO=\"chunked\"") then
            chunked = -1
          end
        else
          if chosen_bitrate and not chosen_url then
            chosen_url = urlparse.absolute(url, line)
          end
          if chunked == -1 then
            chunked = urlparse.absolute(url, line)
          end
        end
      end
      if chunked then
        chosen_url = chunked
      end
      if not chosen_url then
        error("No video URL found.")
      end
      ids[chosen_url] = true
      context["m3u8_url"] = chosen_url
      check(chosen_url)
    end
    if context["m3u8_url"] == url then
      for line in string.gmatch(html, "([^\n]+)") do
        if not string.match(line, "^#") then
          local newurl = urlparse.absolute(url, line)
          ids[newurl] = true
          check(newurl)
        end
      end
    end
    if string.match(url, "^https?://gql%.twitch%.tv/gql") then
      json = cjson.decode(html)
      if json["extensions"] then
        json = {json}
      end
      if json["error"] or json["errors"] then
        error("Got error " .. html .. ".")
      end
      for _, data in pairs(json) do
        if data["error"] or data["errors"] then
          error("Got error " .. cjson.encode(data) .. ".")
        end
        local extensions = data["extensions"]
        if extensions then
          operation_name = extensions["operationName"]
          if operation_name == "VideoPreviewCard__VideoMoments" then
            context["exists"] = data["data"]["video"] ~= cjson.null
            if not context["exists"] then
              print("Video does not exist.")
              context["queries_todo"] = {}
            end
            context["existence_checked"] = true
          elseif operation_name == "PlaybackAccessToken_Template" then
            context["playback_signature"] = data["data"]["videoPlaybackAccessToken"]["signature"]
            context["playback_token"] = data["data"]["videoPlaybackAccessToken"]["value"]
            if not context["player_version"] then
              error("No player version was found.")
            end
            check(
              "https://usher.ttvnw.net/vod/" .. item_value .. ".m3u8"
              .. "?acmb=" .. urlparse.escape(base64.encode(cjson.encode({["AppVersion"]=context["app_version"]})))
              .. "&allow_source=true"
              .. "&browser_family=firefox"
              .. "&browser_version=128.0"
              .. "&cdm=wv"
            --  .. "&enable_score=true"
              .. "&os_name=Linux"
              .. "&os_version=undefined"
              .. "&p=9000000"
              .. "&platform=web"
              .. "&play_session_id=00000000000000000000000000000000"
              .. "&player_backend=mediaplayer"
              .. "&player_version=" .. context["player_version"]
              .. "&playlist_include_framerate=true"
              .. "&reassignments_supported=true"
              .. "&sig=" .. context["playback_signature"]
              .. "&supported_codecs=av1,h264"
              .. "&token=" .. urlparse.escape(context["playback_token"])
              .. "&transcode_mode=cbr_v1"
            )
          elseif operation_name == "ChannelVideoCore" then
            if data["data"]["video"]["id"] ~= item_value then
              error("Data for wrong video ID found.")
            end
            context["channel_id"] = data["data"]["video"]["owner"]["id"]
            context["username"] = data["data"]["video"]["owner"]["login"]
            if not context["channel_id"]
              or not context["username"] then
              error("Could not extract channel information.")
            end
          elseif operation_name == "VideoCommentsByOffsetOrCursor" then
            if data["data"]["video"]["comments"]["pageInfo"]["hasNextPage"] then
              local cursor = nil
              for _, comment_data in pairs(data["data"]["video"]["comments"]["edges"]) do
                if not cursor then
                  cursor = comment_data["cursor"]
                elseif cursor ~= comment_data["cursor"] then
                  error("Found multiple different comment cursors.")
                end
              end
              if not cursor then
                error("Could not find comment cursor.")
              end
              --error("Multiple comment pages are currently not supported.")
              submit_graphql(cjson.encode({{
                ["operationName"]="VideoCommentsByOffsetOrCursor",
                ["variables"]={
                  ["videoID"]=item_value,
                  ["cursor"]=cursor
                },
                ["extensions"]={
                  ["persistedQuery"]={
                    ["version"]=1,
                    ["sha256Hash"]="b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"
                  }
                }
              }}))
            end
          end
        end
      end
    end
    if context["queries_queued"] then --and context["client_integrity"] then
      local new_todo = {}
      for _, queries in pairs(context["queries_todo"]) do
        local encoded = cjson.encode(queries)
        if not context["exists"] then
          table.insert(new_todo, queries)
          if string.match(encoded, "VideoPreviewCard__VideoMoments")
            and not submit_graphql(encoded) then
            error("Could not submit previewcard GQL request.")
          end
        else
          if not submit_graphql(encoded) then
            table.insert(new_todo, queries)
          elseif not queries["operationName"] then
            for _, query in pairs(queries) do
              query = cjson.encode(query)
              if string.match(query, "###") then
                submit_graphql("[" .. query .. "]")
              end
            end
          end
        end
      end
      context["queries_todo"] = new_todo
    end
    for newurl in string.gmatch(string.gsub(html, "&[qQ][uU][oO][tT];", '"'), '([^"]+)') do
      if json then
        check(newurl)
      else
        checknewurl(newurl)
      end
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      if json then
        check(newurl)
      else
        checknewurl(newurl)
      end
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    html = string.gsub(html, "&gt;", ">")
    html = string.gsub(html, "&lt;", "<")
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  is_initial_url = false
  if string.match(url["url"], "^https?://assets%.twitch%.tv/assets/player%-core%-base%-")
    and ids[url["url"]]
    and math.random() < 0.95 then
    return false
  end
  if string.match(url["url"], "^https?://[^/]*/gql") then
    local html = read_file(http_stat["local_file"])
    --[[if string.match(html, "VideoCommentsByOffsetOrCursor")
      and string.match(html, '"hasNextPage"%s*:%s*true') then
      print("This item has multiple comment pages, this is unsupported still.")
      context["queries_todo"] = {}
      abort_item()
      return false
    end]]
    if string.match(html, "\"errors?\"%s*:") then
      print("Found an error in the GQL response.")
      retry_url = true
      return false
    end
  end
  if http_stat["statcode"] ~= 200
    and (
      http_stat["statcode"] ~= 403
      or not string.match(url["url"], "^https://[^%.]+%.cloudfront%.net/.+/storyboards/[0-9]+%-[a-z]+%-?[0-9]?%.j[ps][go]n?$")
    ) then
    print("Incorrect status code.")
    retry_url = true
    return false
  end
  if http_stat["len"] == 0
    and http_stat["statcode"] < 300 then
    print("Found 0 bytes downloaded.")
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 9
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 then
      if not seen_200[url["url"]] then
        seen_200[url["url"]] = 0
      end
      seen_200[url["url"]] = seen_200[url["url"]] + 1
    end
    downloaded[url["url"]] = true
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["twitch-9lfrm8le7twbsgnu"] = discovered_items,
    ["urls-u1842o4e7gbvj72p"] = discovered_outlinks
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab then
    abort_item()
  else
    check_item_complete()
  end
  if killgrab then
    return wget.exits.IO_FAIL
  end
  return exit_status
end


