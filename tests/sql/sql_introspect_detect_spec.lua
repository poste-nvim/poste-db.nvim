local detect = require("poste-db.introspect.detect")

describe("introspect detect helpers", function()
  it("finds the statement block around the current line", function()
    local lines = {
      "-- @connection primary",
      "###",
      "SELECT * FROM authors;",
      "SELECT * FROM posts;",
      "###",
      "SELECT * FROM comments;",
    }

    local start_line, end_line = detect.find_block_for_line(lines, 3)
    assert.equals(3, start_line)
    assert.equals(4, end_line)

    start_line, end_line = detect.find_block_for_line(lines, 6)
    assert.equals(6, start_line)
    assert.equals(6, end_line)
  end)

  -- The block scanner used a bare `^###` while nav's scanner used the house
  -- helper (BOM-tolerant, leading whitespace allowed): the same file split into
  -- different sections depending on which path looked at it.
  it("recognizes indented and BOM-prefixed section markers", function()
    local bom = "\239\187\191###"
    local lines = {
      "SELECT 1;",
      "  ###",
      "SELECT 2;",
      bom,
      "SELECT 3;",
    }

    local start_line, end_line = detect.find_block_for_line(lines, 3)
    assert.equals(3, start_line)
    assert.equals(3, end_line)
  end)

  it("builds a detect payload from the surrounding block", function()
    local lines = {
      "-- @connection primary",
      "###",
      "SELECT * FROM authors;",
      "SELECT * FROM posts;",
      "###",
      "SELECT * FROM comments;",
    }

    local payload = detect.build_detect_payload(lines, 3, 6)
    assert.same({
      block_start = 3,
      block_end = 4,
      sql_text = "SELECT * FROM authors;\nSELECT * FROM posts;",
      offset = 5,
      line_text = "SELECT * FROM authors;",
    }, payload)
  end)

  it("treats the whole buffer as one block when no ### markers exist", function()
    local lines = {
      "SELECT * FROM authors;",
      "SELECT * FROM posts;",
    }

    local payload = detect.build_detect_payload(lines, 1, 6)
    assert.same({
      block_start = 1,
      block_end = 2,
      sql_text = "SELECT * FROM authors;\nSELECT * FROM posts;",
      offset = 5,
      line_text = "SELECT * FROM authors;",
    }, payload)
  end)
end)
