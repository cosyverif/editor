local respond_to = require "lapis.application".respond_to
local Model      = require "cosy.server.model"

return function (app)

  app:match ("/users(/)", respond_to {
    GET = function ()
      local users = {}
      for i, user in ipairs (Model.user:select ()) do
        print (i, user.id)
        users [i] = {
          id = user.id,
        }
      end
      return {
        status = 200,
        json   = users,
      }
    end,
    POST = function (self)
      if not self.user then
        return {
          status = 401,
        }
      end
      Model.user:create {
        id = self.user.id,
      }
      return {
        status = 201,
      }
    end,
  })

  app:match ("/users/:user(/)", respond_to {
    GET = function (self)
      local id   = self.params.user
      print ("looking for", id)
      local user = Model.user:find (id)
      if not user then
        return {
          status = 404,
        }
      end
      local projects = {}
      for i, project in ipairs (Model.project:find {
        user = id,
      }) do
        projects [i] = {
          id = project.id,
        }
      end
      return {
        status = 200,
        json   = {
          id       = user.id,
          projects = projects,
        },
      }
    end,
    PATCH = function (self)
      local id = self.params.user
      if not self.user then
        return {
          status = 401,
        }
      end
      if self.user.id ~= id then
        return {
          status = 403,
        }
      end
      local user = Model.user:find (id)
      if not user then
        return {
          status = 404,
        }
      end
      -- TODO
      return {
        status = 204,
      }
    end,
    DELETE = function (self)
      local id = self.params.user
      if not self.user then
        return {
          status = 401,
        }
      end
      if self.user.id ~= id then
        return {
          status = 403,
        }
      end
      local user = Model.user:find (id)
      if not user then
        return {
          status = 404,
        }
      end
      user:delete ()
      return {
        status = 204,
      }
    end,
  })

end
