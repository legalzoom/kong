local b64 = require "ngx.base64"
local cjson = require "cjson.safe"


local fmt = string.format
local type = type
local pairs = pairs


local function extract(conf)
  local refs = conf["$refs"]
  if not refs or type(refs) ~= "table" then
    return
  end

  local secrets = {}
  for k in pairs(refs) do
    secrets[k] = conf[k]
  end

  return secrets
end


local function serialize(input)
  local output, err = cjson.encode(input)
  if not output then
    return nil, fmt("failed to json encode process secrets: %s", err)
  end

  output, err = b64.encode_base64url(output)
  if not output then
    return nil, fmt("failed to base64 encode process secrets: %s", err)
  end

  return output
end


local function deserialize(input)
  local output, err = b64.decode_base64url(input)
  if not output then
    return nil, fmt("failed to base64 decode process secrets: %s", err)
  end

  output, err = cjson.decode(output)
  if not output then
    return nil, fmt("failed to json decode process secrets: %s", err)
  end

  return output
end



return {
  extract = extract,
  serialize = serialize,
  deserialize = deserialize,
}
