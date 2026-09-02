defmodule Symphony.PlannersTest do
  use ExUnit.Case, async: true

  alias Symphony.Planners

  test "recognizes a tombstone only at the end of the last comment" do
    refute Planners.done?(%{comments: [%{content: "Use ∎ in the template."}]})
    assert Planners.done?(%{comments: [%{content: "Blocked ∎"}]})
  end
end
