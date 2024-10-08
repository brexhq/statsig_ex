defmodule StatsigEx.PressureTest do
  import ExUnit.Assertions
  @unsupported_conditions ["ip_based"]
  @unsupported_gates ["test_id_list", "test_not_in_id_list"]
  @unsupported_configs ["test_exp_50_50_with_targeting_v2"]

  def pressure_test_and_compare(func, args, iterations \\ 100) do
    {misses, results} =
      Enum.reduce(1..iterations, {0, []}, fn _, {m, r} ->
        id = :crypto.strong_rand_bytes(10) |> Base.encode64()
        # we should put a bunch more data in here to be sure
        user = %{"userID" => id}
        # function name & arity must be the same in both (this is a good restriction)
        ex_result = apply(StatsigEx, func, [user | args])
        erl_result = apply(:statsig, func, [user | args])

        case {ex_result, erl_result} do
          {a, b} when a == b -> {m, r}
          {a, b} -> {m + 1, [{a, b} | r]}
        end
      end)

    assert misses == 0,
           "expected 0 misses, but got #{misses} | #{inspect(args)} | #{
             inspect(List.first(results))
           }"
  end

  def all_conditions_supported?(gate, :gate, _server)
      when gate in @unsupported_gates,
      do: false

  def all_conditions_supported?(config, :config, _server)
      when config in @unsupported_configs,
      do: false

  def all_conditions_supported?(gate, type, server) do
    case StatsigEx.lookup(gate, type, server) do
      [{_key, spec}] ->
        Enum.reduce(Map.get(spec, "rules"), true, fn %{"conditions" => c}, acc ->
          acc &&
            Enum.reduce(c, true, fn %{"type" => type}, c_acc ->
              c_acc && !Enum.any?(@unsupported_conditions, fn n -> n == type end)
            end)
        end)

      _ ->
        true
    end
  end
end
