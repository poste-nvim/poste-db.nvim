--- The Modify/New-Column form's SQL type provider (blink.cmp source).
--- Its filter used to BIND adapter.completion_item_kind (a function) and then
--- index the binding — "attempt to index a function value" on every
--- keystroke-level completion request. The module needs blink.cmp only for
--- the kind number, so the whole path is testable headless.
local completion = require("poste-db.db_browser.completion")

describe("db_browser type completion", function()
  local saved_dialect

  before_each(function()
    saved_dialect = vim.g.poste_db_dialect
    vim.g.poste_db_dialect = "sqlite"
  end)

  after_each(function()
    if saved_dialect == nil then
      vim.g.poste_db_dialect = nil
    else
      vim.g.poste_db_dialect = saved_dialect
    end
  end)

  local function items_for(keyword)
    local out
    completion.new({}):get_completions({
      get_keyword = function() return keyword end,
    }, function(result) out = result end)
    return out and out.items or {}
  end

  local function labels(items)
    local out = {}
    for _, i in ipairs(items) do out[#out + 1] = i.label end
    return out
  end

  it("returns the dialect's type list without raising", function()
    local labels_list = labels(items_for(""))
    assert.is_true(#labels_list > 0, "an empty keyword lists every sqlite type")
    assert.same(
      { "integer", "real", "text", "blob", "numeric" },
      labels_list,
      "the sqlite list is small enough to pin whole")
  end)

  it("filters by prefix and contains match", function()
    assert.same({ "integer" }, labels(items_for("integ")))
    assert.same({ "integer" }, labels(items_for("eger")))
  end)

  it("falls back to the postgres list for an unknown dialect", function()
    vim.g.poste_db_dialect = "redis"
    local labels_list = labels(items_for("varb"))
    assert.same({ "varbit" }, labels_list, "varbit exists only in the postgres list")
  end)
end)
