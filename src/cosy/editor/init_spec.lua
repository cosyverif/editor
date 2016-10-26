local assert    = require "luassert"
local Copas     = require "copas"
local Et        = require "etlua"
local Jwt       = require "jwt"
local Json      = require "cjson"
local Time      = require "socket".gettime
local Websocket = require "websocket"
local Http      = require "cosy.editor.http"
local Instance  = require "cosy.server.instance"

local Config = {
  auth0       = {
    domain        = assert (os.getenv "AUTH0_DOMAIN"),
    client_id     = assert (os.getenv "AUTH0_ID"    ),
    client_secret = assert (os.getenv "AUTH0_SECRET"),
    api_token     = assert (os.getenv "AUTH0_TOKEN" ),
  },
  docker      = {
    username = assert (os.getenv "DOCKER_USER"  ),
    api_key  = assert (os.getenv "DOCKER_SECRET"),
  },
}

local identities = {
  rahan  = "github|1818862",
  crao   = "google-oauth2|103410538451613086005",
  naouna = "twitter|2572672862",
}

local function make_token (subject, contents, duration)
  local claims = {
    iss = Config.auth0.domain,
    aud = Config.auth0.client_id,
    sub = subject,
    exp = duration and duration ~= math.huge and Time () + duration,
    iat = Time (),
    contents = contents,
  }
  return Jwt.encode (claims, {
    alg = "HS256",
    keys = { private = Config.auth0.client_secret },
  })
end

describe ("editor", function ()

  local instance, server_url

  setup (function ()
    instance   = Instance.create ()
    server_url = instance.server
  end)

  teardown (function ()
    while true do
      local info, status = Http.json {
        url    = server_url,
        method = "GET",
      }
      assert.are.equal (status, 200)
      if info.stats.services == 0 then
        break
      end
      os.execute [[ sleep 1 ]]
    end
  end)

  teardown (function ()
    instance:delete ()
  end)

  local project, resource, project_url, resource_url, users

  before_each (function ()
    users = {}
    for k, v in pairs (identities) do
      local token = make_token (v)
      local result, status = Http.json {
        url     = server_url,
        method  = "GET",
        headers = { Authorization = "Bearer " .. token },
      }
      assert.are.same (status, 200)
      users [k] = result.authentified.path:match "/users/(.*)"
    end
  end)

  before_each (function ()
    local _
    local token = make_token (identities.rahan)
    local result, status = Http.json {
      url     = server_url .. "/projects",
      method  = "POST",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 201)
    project = result.id
    project_url = server_url .. "/projects/" .. project
    _, status = Http.json {
      url     = project_url .. "/permissions/" .. users.crao,
      method  = "PUT",
      body    = { permission = "none" },
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.is_truthy (status == 201 or status == 202)
    _, status = Http.json {
      url     = project_url .. "/permissions/" .. users.naouna,
      method  = "PUT",
      body    = { permission = "read" },
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.is_truthy (status == 201 or status == 202)
    result, status = Http.json {
      url     = project_url .. "/resources",
      method  = "POST",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 201)
    resource = result.id
    resource_url = project_url .. "/resources/" .. resource
  end)

  it ("can be required", function ()
    assert.has.no.errors (function ()
      require "cosy.editor"
    end)
  end)

  it ("can be instantiated", function ()
    assert.has.no.errors (function ()
      local Editor = require "cosy.editor"
      Editor.create {
        api      = server_url,
        port     = 0,
        project  = project,
        resource = resource,
        timeout  = 60,
        token    = make_token (Et.render ("/projects/<%- project %>", {
          project  = project,
        }), {}, math.huge),
      }
    end)
  end)

  it ("cannot start without resource", function ()
    local Editor = require "cosy.editor"
    local token  = make_token (identities.rahan)
    local _, status = Http.json {
      url     = resource_url,
      method  = "DELETE",
      headers = {
        Authorization = "Bearer " .. token,
      },
    }
    assert.are.same (status, 204)
    local editor = Editor.create {
      api      = server_url,
      port     = 0,
      project  = project,
      resource = resource,
      timeout  = 60,
      token    = make_token (Et.render ("/projects/<%- project %>", {
        project  = project,
      }), {}, math.huge),
    }
    assert.has.errors (function ()
      editor:start ()
    end)
  end)

  describe ("correctly configured", function ()

    local editor

    before_each (function ()
      local Editor = require "cosy.editor"
      editor = Editor.create {
        api      = server_url,
        port     = 0,
        project  = project,
        resource = resource,
        timeout  = 60,
        token    = make_token (Et.render ("/projects/<%- project %>", {
          project  = project,
        }), {}, math.huge),
      }
      editor:start ()
    end)

    it ("can be started and stopped", function ()
      Copas.addthread (function ()
        Copas.sleep (1)
        editor:stop ()
      end)
      Copas.loop ()
    end)

    it ("can receive connections", function ()
      local connected
      Copas.addthread (function ()
        Copas.sleep (1)
        local url = Et.render ("ws://<%- host %>:<%- port %>", {
          host = editor.host,
          port = editor.port,
        })
        local client = Websocket.client.copas { timeout = 5 }
        connected    = client:connect (url, "cosy")
        editor:stop ()
      end)
      Copas.loop ()
      assert.is_truthy (connected)
    end)

    it ("cannot receive incorrect messages", function ()
      local answers = {}
      Copas.addthread (function ()
        Copas.sleep (1)
        local url = Et.render ("ws://<%- host %>:<%- port %>", {
          host = editor.host,
          port = editor.port,
        })
        local client = Websocket.client.copas { timeout = 5 }
        client:connect (url, "cosy")
        client:send (Json.encode "message")
        answers [#answers+1] = client:receive ()
        client:send (Json.encode { type = "type" })
        answers [#answers+1] = client:receive ()
        client:send (Json.encode { id = "id" })
        answers [#answers+1] = client:receive ()
        client:send (Json.encode { type = "type", id = "id" })
        answers [#answers+1] = client:receive ()
        client:close ()
        editor:stop ()
      end)
      Copas.loop ()
      for i, answer in ipairs (answers) do
        answers [i] = Json.decode (answer)
      end
      assert.are.same (answers [1], {
        type    = "answer",
        success = false,
        reason  = "invalid message",
      })
      assert.are.same (answers [2], {
        type    = "answer",
        success = false,
        reason  = "invalid message",
      })
      assert.are.same (answers [3], {
        id      = "id",
        type    = "answer",
        success = false,
        reason  = "invalid message",
      })
      assert.are.same (answers [4], {
        id      = "id",
        type    = "answer",
        success = false,
        reason  = "invalid message",
      })
    end)

    it ("checks read access on authentication", function ()
      local answers = {
        n = 0,
      }
      for name, user in pairs (users) do
        Copas.addthread (function ()
          Copas.sleep (1)
          local url = Et.render ("ws://<%- host %>:<%- port %>", {
            host = editor.host,
            port = editor.port,
          })
          local client = Websocket.client.copas { timeout = 5 }
          client:connect (url, "cosy")
          client:send (Json.encode {
            type  = "authenticate",
            id    = 1,
            user  = user,
            token = make_token (identities [name]),
          })
          answers [name] = client:receive ()
          if name ~= "crao" then
            client:receive ()
          end
          client:close ()
          answers.n = answers.n + 1
          if answers.n == 3 then
            editor:stop ()
          end
        end)
      end
      Copas.loop ()
      for name, answer in pairs (answers) do
        answers [name] = Json.decode (answer)
      end
      assert.are.same (answers.rahan, {
        id      = 1,
        type    = "answer",
        success = true,
      })
      assert.are.same (answers.naouna, {
        id      = 1,
        type    = "answer",
        success = true,
      })
      assert.are.same (answers.crao, {
        id      = 1,
        type    = "answer",
        success = false,
        reason  = "authentication failure",
      })
    end)

    it ("sends the model on authentication", function ()
      local answers = {}
      Copas.addthread (function ()
        Copas.sleep (1)
        local url = Et.render ("ws://<%- host %>:<%- port %>", {
          host = editor.host,
          port = editor.port,
        })
        local client = Websocket.client.copas { timeout = 5 }
        client:connect (url, "cosy")
        client:send (Json.encode {
          type  = "authenticate",
          id    = 1,
          user  = users.rahan,
          token = make_token (identities.rahan),
        })
        answers [#answers+1] = client:receive ()
        answers [#answers+1] = client:receive ()
        client:close ()
        editor:stop ()
      end)
      Copas.loop ()
      for i, answer in ipairs (answers) do
        answers [i] = Json.decode (answer)
      end
      assert.are.same (answers [1], {
        id      = 1,
        type    = "answer",
        success = true,
      })
      assert.are.equal (answers [2].type, "update")
    end)

    it ("applies or denies patches depending on permissions", function ()
      local answers = {
        n = 0,
      }
      for name, user in pairs (users) do
        answers [name] = {}
        local my_answers = answers [name]
        Copas.addthread (function ()
          Copas.sleep (1)
          local url = Et.render ("ws://<%- host %>:<%- port %>", {
            host = editor.host,
            port = editor.port,
          })
          local client = Websocket.client.copas { timeout = 5 }
          client:connect (url, "cosy")
          client:send (Json.encode {
            id    = 1,
            type  = "authenticate",
            user  = user,
            token = make_token (identities [name]),
          })
          my_answers [#my_answers+1] = client:receive ()
          if name ~= "crao" then
            my_answers [#my_answers+1] = client:receive ()
          end
          client:send (Json.encode {
            id    = 2,
            type  = "patch",
            patch = "return function () return true end",
          })
          my_answers [#my_answers+1] = client:receive ()
          if name == "naouna" then
            my_answers [#my_answers+1] = client:receive ()
          end
          client:close ()
          answers.n = answers.n + 1
          if answers.n == 3 then
            editor:stop ()
          end
        end)
      end
      Copas.loop ()
      for _, t in pairs (answers) do
        if type (t) == "table" then
          for i, answer in ipairs (t) do
            t [i] = Json.decode (answer)
          end
        end
      end
      assert.is_falsy  (answers.crao   [1].success)
      assert.is_falsy  (answers.crao   [2].success)
      assert.is_truthy (answers.rahan  [1].success)
      assert.are_equal (answers.rahan  [2].type, "update")
      assert.is_truthy (answers.rahan  [3].success)
      assert.is_truthy (answers.naouna [1].success)
      assert.are_equal (answers.naouna [2].type, "update")
      if answers.naouna [3].id == 2 then
        answers.naouna [3], answers.naouna [4] = answers.naouna [4], answers.naouna [3]
      end
      assert.are_equal (answers.naouna [3].type, "update")
      assert.is_falsy  (answers.naouna [4].success)
    end)

    it ("correctly loads dependencies", function ()
      local answers        = {}
      local token          = make_token (identities.crao)
      local result, status = Http.json {
        url     = server_url .. "/projects",
        method  = "POST",
        headers = {
          Authorization = "Bearer " .. token,
        },
      }
      assert.are.same (status, 201)
      local crao_project     = result.id
      local crao_project_url = server_url .. "/projects/" .. crao_project
      result, status = Http.json {
        url     = crao_project_url .. "/resources",
        method  = "POST",
        headers = {
          Authorization = "Bearer " .. token,
        },
      }
      assert.are.same (status, 201)
      local crao_resource = result.id
      local _
      _, status = Http.json {
        url     = crao_project_url .. "/permissions/" .. project,
        method  = "PUT",
        body    = { permission = "read" },
        headers = {
          Authorization = "Bearer " .. token,
        },
      }
      assert.is_truthy (status == 201 or status == 202)
      Copas.addthread (function ()
        Copas.sleep (1)
        local url = Et.render ("ws://<%- host %>:<%- port %>", {
          host = editor.host,
          port = editor.port,
        })
        local client = Websocket.client.copas { timeout = 5 }
        client:connect (url, "cosy")
        client:send (Json.encode {
          id    = 1,
          type  = "authenticate",
          user  = users.rahan,
          token = make_token (identities.rahan),
        })
        answers [#answers+1] = client:receive ()
        answers [#answers+1] = client:receive ()
        client:send (Json.encode {
          id    = 2,
          type  = "patch",
          patch = Et.render ([[
            return function (Layer)
              local dependency = Layer.require "<%- project %>/<%- resource %>"
            end
          ]], {
            project  = crao_project,
            resource = crao_resource,
          }),
        })
        answers [#answers+1] = client:receive ()
        editor:stop ()
      end)
      Copas.loop ()
      for i, answer in ipairs (answers) do
        answers [i] = Json.decode (answer)
      end
      assert.is_truthy (answers [1].success)
      assert.is_truthy (answers [2].type == "update")
      assert.is_truthy (answers [3].success)
    end)

    it ("fails at loading unreadable dependencies", function ()
      local answers        = {}
      local token          = make_token (identities.crao)
      local result, status = Http.json {
        url     = server_url .. "/projects",
        method  = "POST",
        headers = {
          Authorization = "Bearer " .. token,
        },
      }
      assert.are.same (status, 201)
      local crao_project     = result.id
      local crao_project_url = server_url .. "/projects/" .. crao_project
      result, status = Http.json {
        url     = crao_project_url .. "/resources",
        method  = "POST",
        headers = {
          Authorization = "Bearer " .. token,
        },
      }
      assert.are.same (status, 201)
      local crao_resource = result.id
      local _
      _, status = Http.json {
        url     = crao_project_url .. "/permissions/" .. project,
        method  = "PUT",
        body    = { permission = "none" },
        headers = {
          Authorization = "Bearer " .. token,
        },
      }
      assert.is_truthy (status == 201 or status == 202)
      Copas.addthread (function ()
        Copas.sleep (1)
        local url = Et.render ("ws://<%- host %>:<%- port %>", {
          host = editor.host,
          port = editor.port,
        })
        local client = Websocket.client.copas { timeout = 5 }
        client:connect (url, "cosy")
        client:send (Json.encode {
          id    = 1,
          type  = "authenticate",
          user  = users.rahan,
          token = make_token (identities.rahan),
        })
        answers [#answers+1] = client:receive ()
        answers [#answers+1] = client:receive ()
        client:send (Json.encode {
          id    = 2,
          type  = "patch",
          patch = Et.render ([[
            return function (Layer)
              local dependency = Layer.require "<%- project %>/<%- resource %>"
            end
          ]], {
            project  = crao_project,
            resource = crao_resource,
          }),
        })
        answers [#answers+1] = client:receive ()
        editor:stop ()
      end)
      Copas.loop ()
      for i, answer in ipairs (answers) do
        answers [i] = Json.decode (answer)
      end
      assert.is_truthy (answers [1].success)
      assert.is_truthy (answers [2].type == "update")
      assert.is_falsy  (answers [3].success)
    end)

  end)

end)
