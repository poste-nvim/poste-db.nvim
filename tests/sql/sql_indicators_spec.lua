-- Pins the pure text builders behind the request-line indicator. The request
-- path (sql_runner / sql_runner.response) only ever sends `latency_ms`, so
-- `format_latency`, `build_assertion_text` and `build_virt_text` have no
-- production exercise for their boundary shapes — they are exposed through
-- `_test` for exactly this spec.
local indicators = require("poste-db.indicators")

local t = indicators._test

describe("indicators.format_latency", function()
  it("renders sub-second latencies in milliseconds", function()
    assert.equals("0.00 ms", t.format_latency(0))
    assert.equals("1.00 ms", t.format_latency(1))
    assert.equals("999.00 ms", t.format_latency(999))
  end)

  it("renders whole seconds without a fractional tail", function()
    assert.equals("1.00 s", t.format_latency(1000))
  end)

  it("renders fractional seconds with two decimal places", function()
    assert.equals("1.50 s", t.format_latency(1500))
    assert.equals("12.35 s", t.format_latency(12345))
  end)
end)

describe("indicators.build_assertion_text", function()
  it("returns nil for a missing summary", function()
    assert.is_nil(t.build_assertion_text(nil))
    assert.is_nil(t.build_assertion_text({}))
    assert.is_nil(t.build_assertion_text({ total = 0 }))
  end)

  it("reports a failure summary in red", function()
    assert.same({ text = "✘ 1/3 tests", hl = "PosteError" },
      t.build_assertion_text({ total = 3, failed = 1, passed = 2 }))
  end)

  it("reports a pass summary in green", function()
    assert.same({ text = "✓ 3/3 tests", hl = "PosteSuccess" },
      t.build_assertion_text({ total = 3, failed = 0, passed = 3 }))
  end)
end)

describe("indicators.build_virt_text", function()
  it("returns an empty list for no latency and no assertions", function()
    assert.same({}, t.build_virt_text(nil, nil))
    assert.same({}, t.build_virt_text(0, nil))
  end)

  it("appends only the latency item when there are no assertions", function()
    assert.same({ { " 1.50 s", "PosteLatency" } }, t.build_virt_text(1500, nil))
  end)

  it("appends only the assertion item when latency is absent", function()
    assert.same({ { " ✘ 1/3 tests", "PosteError" } },
      t.build_virt_text(nil, { total = 3, failed = 1, passed = 2 }))
  end)

  it("appends latency then assertion in that order", function()
    assert.same({
      { " 1.50 s", "PosteLatency" },
      { " ✓ 3/3 tests", "PosteSuccess" },
    }, t.build_virt_text(1500, { total = 3, failed = 0, passed = 3 }))
  end)
end)
