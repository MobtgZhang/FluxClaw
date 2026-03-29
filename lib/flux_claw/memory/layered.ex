defmodule FluxClaw.Memory.Layered do
  @moduledoc "In-process L2 facts for one agent (L0/L3 come from config and DB recall)."

  defstruct l2: %{}

  @type t :: %__MODULE__{l2: map()}
end
