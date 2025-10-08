local log      = require("lib.log")
local metadata = require("lib.metadata")
local config   = require("helpers.config")
local utils    = require("helpers.utils")
local muos     = require("helpers.muos")
local pprint   = require("lib.pprint")

local artwork  = {
  cached_game_ids = {},
}


local output_types = {
  BOX = "box",
  PREVIEW = "preview",
  SPLASH = "splash",
}

artwork.output_map = {
  [output_types.BOX] = "covers",
  [output_types.PREVIEW] = "screenshots",
  [output_types.SPLASH] = "wheels",
}

local user_config, skyscraper_config = config.user_config, config.skyscraper_config

-- Normalize internal distinctions to Skyscraper/peas output folder keys
local function normalize_platform(platform)
  local map = {
    ["pcengine_"] = "pcengine",
    ["coleco_"] = "coleco",
  }
  return map[platform] or platform
end

function artwork.get_artwork_path()
  local artwork_xml = skyscraper_config:read("main", "artworkXml")
  if not artwork_xml or artwork_xml == "\"\"" then return nil end
  artwork_xml = artwork_xml:gsub('"', '')
  return artwork_xml
end

function artwork.get_artwork_name()
  local artwork_path = artwork.get_artwork_path()
  if not artwork_path then return nil end
  local artwork_name = artwork_path:match("([^/]+)%.xml$")
  return artwork_name
end

function artwork.get_template_resolution(xml_path)
  local xml_content = nativefs.read(xml_path)
  if not xml_content then
    return nil
  end

  local width, height = xml_content:match('<output [^>]*width="(%d+)"[^>]*height="(%d+)"')

  if width and height then
    return width .. "x" .. height
  end
  return nil
end

function artwork.get_output_types(xml_path)
  local xml_content = nativefs.read(xml_path)
  local result = {
    box = false,
    preview = false,
    splash = false
  }

  if not xml_content then return result end

  if xml_content:find('<output [^>]*type="cover"') then
    result.box = true
  end
  if xml_content:find('<output [^>]*type="screenshot"') then
    result.preview = true
  end
  if xml_content:find('<output [^>]*type="wheel"') then
    result.splash = true
  end

  return result
end

function artwork.copy_artwork_type(platform, game, media_path, copy_path, output_type)
  --[[
    platform -> nes | gb | gba | ...
    game -> "Super Mario World"
    media_path -> "data/output/{platform}/media"
    copy_path -> "/mnt/mmc/MUOS/info/catalogue/Platform Title/{type}"
    output_type -> box | preview | splash
  --]]

  -- Find scraped artwork in output folder
  local scraped_art_path = string.format("%s/%s/%s.png", media_path, artwork.output_map[output_type], game)
  local scraped_art = nativefs.newFileData(scraped_art_path)
  if not scraped_art then
    log.write(string.format("Scraped artwork not found for output '%s'", artwork.output_map[output_type]))
    return
  end

  -- Ensure destination directory exists
  local dest_dir = string.format("%s/%s", copy_path, output_type)
  if not nativefs.getInfo(dest_dir) then
    nativefs.createDirectory(dest_dir)
  end
  -- Copy to catalogue
  local _, err = nativefs.write(string.format("%s/%s/%s.png", copy_path, output_type, game), scraped_art)
  if err then
    log.write(err)
  end
end

function artwork.copy_to_catalogue(platform, game)
  log.write(string.format("Copying artwork for %s: %s", platform, game))
  local _, output_path = skyscraper_config:get_paths()
  local _, catalogue_path = user_config:get_paths()
  if output_path == nil or catalogue_path == nil then
    log.write("Missing paths from config")
    return
  end
  output_path = utils.strip_quotes(output_path)
  local platform_str = muos.platforms[platform]
  if not platform_str then
    log.write("Catalogue destination folder not found")
    return
  end

  local pea_key = normalize_platform(platform)
  local media_path = string.format("%s/%s/media", output_path, pea_key)
  local copy_path = string.format("%s/%s", catalogue_path, platform_str)

  -- Create platform directory and common subfolders if missing
  if not nativefs.getInfo(copy_path) then
    nativefs.createDirectory(copy_path)
  end
  local ensure_dirs = { "box", "preview", "splash", "text" }
  for _, d in ipairs(ensure_dirs) do
    local p = string.format("%s/%s", copy_path, d)
    if not nativefs.getInfo(p) then nativefs.createDirectory(p) end
  end

  -- Copy box/cover artwork
  artwork.copy_artwork_type(platform, game, media_path, copy_path, output_types.BOX)
  -- Copy preview artwork
  artwork.copy_artwork_type(platform, game, media_path, copy_path, output_types.PREVIEW)
  -- Copy splash artwork
  artwork.copy_artwork_type(platform, game, media_path, copy_path, output_types.SPLASH)

  -----------------------------
  -- Read Pegasus-formatted metadata
  -----------------------------
  local file = nativefs.read(string.format("%s/%s/metadata.pegasus.txt", output_path, platform))
  if file then
    local games = metadata.parse(file)
    if games then
      for _, entry in ipairs(games) do
        if entry.filename == game then
          print(string.format("Writing desc for %s", game))
          local _, err = nativefs.write(string.format("%s/text/%s.txt", copy_path, game),
            string.format("%s\nGenre: %s", entry.description, entry.genre))
          if err then log.write(err) end
          break
        end
      end
    end
  else
    log.write("Failed to load metadata.pegasus.txt for " .. platform)
  end
end

function artwork.process_cached_by_platform(platform, cache_folder)
  local quick_id_entries = {}
  local cached_games = {}

  if not cache_folder then
    cache_folder = skyscraper_config:read("main", "cacheFolder")
    if not cache_folder or cache_folder == "\"\"" then
      return
    end
    cache_folder = utils.strip_quotes(cache_folder)
  end

  -- Read quickid and db files
  local quickid = nativefs.read(string.format("%s/%s/quickid.xml", cache_folder, platform))
  local db = nativefs.read(string.format("%s/%s/db.xml", cache_folder, platform))

  if not quickid or not db then
    log.write("Missing quickid.xml or db.xml for " .. platform)
    return
  end

  -- Parse quickid for ROM identifiers
  local lines = utils.split(quickid, "\n")
  for _, line in ipairs(lines) do
    if line:find("<quickid%s") then
      local filepath = line:match('filepath="([^"]+)"')
      if filepath then
        local filename = filepath:match("([^/]+)$")
        local id = line:match('id="([^"]+)"')
        quick_id_entries[filename] = id
      end
    end
  end

  -- Parse db for resource matching
  local lines = utils.split(db, "\n")
  for _, line in ipairs(lines) do
    if line:find("<resource%s") then
      local id = line:match('id="([^"]+)"')
      if id then
        cached_games[id] = true
      end
    end
  end

  -- Remove entries without matching resources
  for filename, id in pairs(quick_id_entries) do
    if not cached_games[id] then
      quick_id_entries[filename] = nil
    end
  end

  -- pprint(quick_id_entries)

  -- Save entries globally
  artwork.cached_game_ids[platform] = quick_id_entries
end

function artwork.process_cached_data()
  log.write("Processing cached data")
  local cache_folder = skyscraper_config:read("main", "cacheFolder")
  if not cache_folder then return end
  cache_folder = utils.strip_quotes(cache_folder)
  local items = nativefs.getDirectoryItems(cache_folder)
  if not items then return end

  for _, platform in ipairs(items) do
    artwork.process_cached_by_platform(platform)
  end

  pprint(artwork.cached_game_ids)

  log.write("Finished processing cached data")
end

return artwork
