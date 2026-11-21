describe("poste-db.ai.mentions", function()
  local connections = require("poste-db.connections")
  local mentions = require("poste-db.ai.mentions")

  local real_list, real_get_config

  before_each(function()
    real_list = connections.list_connections
    real_get_config = connections.get_connection_config
    mentions.invalidate()
  end)

  after_each(function()
    connections.list_connections = real_list
    connections.get_connection_config = real_get_config
  end)

  describe("candidates", function()
    it("labels connections with their default database", function()
      local got = mentions._candidates({
        { name = "my-blog", dialect = "mysql", host = "h1", database = "blog" },
        { name = "no-db", dialect = "sqlite" },
      })
      assert.are.equal(2, #got)
      assert.are.equal("my-blog/blog", got[1].label)
      assert.truthy(got[1].description:find("mysql"))
      assert.are.equal("no-db/db", got[2].label)
    end)
  end)

  describe("complete", function()
    it("fetches once and re-uses the cached list", function()
      local calls = 0
      connections.list_connections = function(cb)
        calls = calls + 1
        cb({ { name = "c1", dialect = "postgres", database = "d1" } })
      end

      local first, second
      mentions.complete("", function(items) first = items end)
      mentions.complete("", function(items) second = items end)

      assert.are.equal(1, calls)
      assert.are.equal("c1/d1", first[1].label)
      assert.are.equal("c1/d1", second[1].label)
    end)

    it("filters candidates by the typed prefix", function()
      connections.list_connections = function(cb)
        cb({
          { name = "prod", dialect = "postgres", database = "db" },
          { name = "staging", dialect = "postgres", database = "db" },
        })
      end
      mentions.invalidate()

      local items
      mentions.complete("pro", function(list) items = list end)
      assert.are.equal(1, #items)
      assert.are.equal("prod/db", items[1].label)
    end)

    it("refetches after invalidate()", function()
      local calls = 0
      connections.list_connections = function(cb)
        calls = calls + 1
        cb({ { name = "c" .. calls, dialect = "postgres" } })
      end

      local got
      mentions.complete("", function(items) got = items end)
      assert.are.equal("c1/db", got[1].label)

      mentions.invalidate()
      mentions.complete("", function(items) got = items end)
      assert.are.equal("c2/db", got[1].label)
      assert.are.equal(2, calls)
    end)
  end)

  describe("match", function()
    before_each(function()
      connections.get_connection_config = function(name)
        if name == "my-blog" then return { dialect = "mysql" } end
        return nil
      end
    end)

    it("classifies connection/database tokens", function()
      assert.same({ connection = "my-blog", database = "blog" }, mentions.match("my-blog/blog"))
    end)

    it("classifies connection/database/table tokens", function()
      assert.same(
        { connection = "my-blog", database = "blog", table = "users" },
        mentions.match("my-blog/blog/users")
      )
    end)

    it("rejects unknown connections and non-mention tokens", function()
      assert.is_nil(mentions.match("unknown/blog"))
      assert.is_nil(mentions.match("just-a-word"))
    end)

    it("answers nil (not a crash) on a non-string token", function()
      -- a nil/garbage token must fall back to file mentions, not break the
      -- completion that asked
      assert.is_nil(mentions.match(nil))
      assert.is_nil(mentions.match(42))
      assert.is_nil(mentions.match({}))
    end)
  end)
end)
