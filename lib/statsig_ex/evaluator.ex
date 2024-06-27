defmodule StatsigEx.Evaluator do
  # here's what I sitll need to do:
  # * log exposures. These are logs of the gates / configs that are evaluated,
  #   so each gate / config eval should have one primary exposure and N secondary
  #   exposures (one for each pass/fail gate conditions encountered along the way)

  # I think I just need to ignore this return value shape for now,
  # because it's confusing me and holding me back (it doesn't seem consistent anywhere)
  # {Rule, GateValue, JsonValue, ruleID/reason, Exposures}
  # {:ok, result, value, exposures}

  def find_and_eval(user, name, type) do
    case :ets.lookup(StatsigEx.ets_name(), {name, type}) do
      [{_key, spec}] ->
        {result, rule, exp} = do_eval(user, spec)

        {result, rule,
         [
           %{"gate" => name, "gateValue" => to_string(result), "ruleID" => Map.get(rule, "id")}
           | exp
         ]}

      _other ->
        # {:ok, false, :not_found}
        {false, %{}, []}
    end
  end

  # hrm, should this log an exposure...?
  defp do_eval(_user, %{"enabled" => false}), do: {false, %{}, []}
  defp do_eval(user, %{"rules" => rules} = spec), do: eval_rules(user, rules, spec, [])

  defp eval_rules(_user, [], _spec, results) do
    # combine all the exposures and calculate result
    # only one rule needs to pass
    Enum.reduce(results, {false, nil, []}, fn {result, rid, exposures},
                                              {running_result, running_rid, acc} ->
      {result || running_result, running_rid || rid, exposures ++ acc}
    end)
  end

  defp eval_rules(user, [rule | rest], spec, acc) do
    # eval rules, and then
    case eval_one_rule(user, rule, spec) do
      # once we find a passing rule, move on
      {true, rid, exp} ->
        eval_rules(user, [], spec, [
          {eval_pass_percent(user, rule, spec), rid, exp} | acc
        ])

      result ->
        eval_rules(user, rest, spec, [result | acc])
    end
  end

  defp eval_one_rule(user, %{"conditions" => conds} = rule, spec) do
    results = eval_conditions(user, conds, rule, spec)

    Enum.reduce(results, {true, nil, []}, fn {result, rid, exp},
                                             {running_result, running_rid, acc} ->
      {result && running_result, running_rid || rid, exp ++ acc}
    end)
  end

  defp eval_conditions(user, conds, rule, spec, acc \\ [])
  defp eval_conditions(_user, [], _rule, _spec, acc), do: acc
  # public conditions are final, so short-circuit this and return
  defp eval_conditions(user, [%{"type" => "public"} | _rest], rule, spec, acc),
    do: [{eval_pass_percent(user, rule, spec), rule, []} | acc]

  defp eval_conditions(
         user,
         [%{"type" => "pass_gate", "targetValue" => gate} | rest],
         rule,
         spec,
         acc
       ) do
    result =
      case find_and_eval(user, gate, :gate) do
        # I don't think I care about the rule returned below, do I? it should be in the exposure
        # OR, should the rule be the final rule that matched...?
        {true, _rule, exp} -> {eval_pass_percent(user, rule, spec), rule, exp}
        other -> other
      end

    eval_conditions(user, rest, rule, spec, [result | acc])
  end

  defp eval_conditions(
         user,
         [%{"type" => "fail_gate", "targetValue" => gate} | rest],
         rule,
         spec,
         acc
       ) do
    result =
      case find_and_eval(user, gate, :gate) do
        # false is a pass, since this is a FAIL gate check
        {false, _rule, exp} -> {eval_pass_percent(user, rule, spec), rule, exp}
        {true, rid, exp} -> {false, rid, exp}
      end

    eval_conditions(user, rest, rule, spec, [result | acc])
  end

  defp eval_conditions(
         user,
         [%{"targetValue" => target, "operator" => op} = c | rest],
         rule,
         spec,
         acc
       ) do
    val = extract_value_to_compare(user, c)

    result =
      case compare(val, target, op) do
        true -> {eval_pass_percent(user, rule, spec), rule, []}
        r -> {r, rule, []}
      end

    eval_conditions(user, rest, rule, spec, [result | acc])
  end

  defp extract_value_to_compare(user, %{"type" => "user_field", "field" => field}),
    do: get_user_field(user, field)

  defp extract_value_to_compare(user, %{"type" => "environment_field", "field" => field}),
    do: get_env_field(user, field)

  defp extract_value_to_compare(_user, %{"type" => "current_time"}),
    do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)

  defp extract_value_to_compare(user, %{"type" => "unit_id", "idType" => id_type}) do
    get_user_id(user, id_type)
  end

  defp eval_pass_percent(_user, %{"passPercentage" => 100}, _spec), do: true
  defp eval_pass_percent(_user, %{"passPercentage" => 0}, _spec), do: false

  defp eval_pass_percent(user, %{"passPercentage" => perc, "idType" => prop} = rule, spec) do
    spec_salt = Map.get(spec, "salt", Map.get(spec, "id", ""))
    rule_salt = Map.get(rule, "salt", Map.get(rule, "id", ""))
    id = get_user_id(user, prop)
    hash = user_hash("#{spec_salt}.#{rule_salt}.#{id}")
    rem(hash, 10_000) < perc * 100
  end

  # if either is nil, the comparison should fail
  defp compare(val, target, _) when is_nil(val) or is_nil(target), do: false

  # make sure "any" is comparing a list
  defp compare(val, target, "any") when not is_list(target), do: compare(val, [target], "any")

  defp compare(val, target, op) when op in ["any", "any_case_sensitive"],
    do: Enum.any?(target, fn t -> val == t end)

  # basically the opposite of "any"
  defp compare(val, target, op) when op in ["none", "none_case_sensitive"],
    do: !compare(val, target, "any")

  defp compare(val, target, "str_starts_with_any") do
    Enum.any?(target, fn t -> String.starts_with?(val, t) end)
  end

  defp compare(val, target, "str_ends_with_any") do
    Enum.any?(target, fn t -> String.ends_with?(val, t) end)
  end

  defp compare(val, target, "str_contains_any") do
    Enum.any?(target, fn t -> String.contains?(val, t) end)
  end

  defp compare(val, target, "str_contains_none"), do: !compare(val, target, "str_contains_any")

  defp compare(val, target, "str_matches") do
    # make sure the regex can compile
    case Regex.compile(target) do
      {:ok, r} ->
        Regex.match?(r, val)

      _ ->
        false
    end
  end

  defp compare(val, target, "on") do
    {:ok, vd} = DateTime.from_unix(val, :millisecond)
    {:ok, td} = DateTime.from_unix(target, :millisecond)
    vd.year == td.year && vd.month == td.month && vd.day == td.day
  end

  # we probably need to do some type checking here, so we don't compare values of different types
  defp compare(val, target, "after"), do: val > target
  defp compare(val, target, "before"), do: val < target

  defp compare(val, target, "eq"), do: val == target
  defp compare(val, target, "neq"), do: val != target
  defp compare(val, target, "gt"), do: val > target
  defp compare(val, target, "lt"), do: val < target
  defp compare(val, target, "lte"), do: val <= target
  defp compare(val, target, "gte"), do: val >= target

  defp compare(val, target, <<"version_", type::binary>>) do
    # we need to manually parse versions first to avoid raising Version.InvalidVersionError
    # we might consider padding as needed to make version strings all the right length
    case [Version.parse(val), Version.parse(target)] do
      [{:ok, v}, {:ok, t}] ->
        compare_versions(v, t, type)

      _ ->
        IO.puts("invalid version")
        false
    end
  end

  defp compare(_, _, op) do
    IO.inspect(op, label: :unsupported_compare)
    false
  end

  defp compare_versions(val, target, "gt"), do: Version.compare(val, target) == :gt
  defp compare_versions(val, target, "lt"), do: Version.compare(val, target) == :lt
  defp compare_versions(val, target, "eq"), do: Version.compare(val, target) == :eq
  defp compare_versions(val, target, "neq"), do: Version.compare(val, target) != :eq

  defp compare_versions(val, target, "gte"),
    do: Enum.member?([:gt, :eq], Version.compare(val, target))

  defp compare_versions(val, target, "lte"),
    do: Enum.member?([:lt, :eq], Version.compare(val, target))

  defp user_hash(s) do
    <<hash::size(64), _rest::binary>> = :crypto.hash(:sha256, s)
    hash
  end

  defp get_user_id(user, "userID" = prop), do: try_get_with_lower(user, prop) |> to_string()

  defp get_user_id(user, prop),
    do: try_get_with_lower(Map.get(user, "customIDs", %{}), prop) |> to_string()

  # this is kind of messy, but it should work for now
  defp get_user_field(user, prop) do
    case try_get_with_lower(user, prop) do
      nil -> try_get_with_lower(Map.get(user, "custom", %{}), prop)
      found -> found
    end
    |> case do
      nil -> try_get_with_lower(Map.get(user, "privateAttributes", %{}), prop)
      found -> found
    end
  end

  defp get_env_field(%{"statsigEnvironment" => env}, field),
    do: try_get_with_lower(env, field) |> to_string()

  defp get_env_field(_, _), do: nil

  defp try_get_with_lower(obj, prop) do
    lower = String.downcase(prop)

    case Map.get(obj, prop) do
      x when x == nil or x == [] or x == "" -> Map.get(obj, lower)
      x -> x
    end
  end
end
