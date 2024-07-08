defmodule StatsigEx.ExposureLoggingTest do
  use ExUnit.Case
  import StatsigEx.PressureTest
  alias StatsigEx.Evaluator

  test "all existing configs" do
    data =
      "test/data/rulesets_e2e_expected_results.json"
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("data")
      |> Enum.each(fn %{"user" => user, "dynamic_configs" => configs} ->
        Enum.each(configs, fn {name, %{"secondary_exposures" => sec}} ->
          IO.inspect(user)
          IO.inspect(name)

          if all_conditions_supported?(name, :config) && name != "inline_targeting_rules_exp" do
            [prim | exp] = Evaluator.eval(user, name, :config).exposures
            assert Enum.sort(exp) == Enum.sort(sec)
          end
        end)
      end)
  end

  @tag :skip
  test "one config" do
    user = %{
      "appVersion" => "1.2.3-alpha",
      "ip" => "1.0.0.0",
      "locale" => "en_US",
      "userAgent" =>
        "Mozilla/5.0 (iPhone; CPU iPhone OS 10_3_1 like Mac OS X) AppleWebKit/603.1.30 (KHTML, like Gecko) Version/10.0 Mobile/14E304 Safari/602.1",
      "userID" => "123"
    }

    exp_secondary = [
      %{
        "gate" => "global_holdout",
        "gateValue" => "false",
        "ruleID" => "3QoA4ncNdVGBaMt3N1KYjz:0.50:1"
      }
      # %{
      #   "gate" => "segment:inline_targeting_rules_exp",
      #   "gateValue" => "true",
      #   "ruleID" => "57irdfAFMZqlbOdaF481RB"
      # }
    ]

    name = "inline_targeting_rules_exp"
    %{exposures: [prim | exp]} = Evaluator.eval(user, name, :config)
    IO.inspect(prim, label: :result)
    assert Enum.sort(exp) == Enum.sort(exp_secondary)
    # compare_logs(user, name, :config)
  end

  defp compare_with_expected(user, id, type) do
    flush()
    result = Evaluator.eval(user, id, type)
  end

  defp compare_logs(user, id, type) do
    flush()
    check(user, id, type)
    [{_, erl_logs} | _rest] = GenServer.call(:statsig_server, {:state})
    %{events: ex_logs} = StatsigEx.state()

    # the time is never gonna match, but _everything_ else should
    erl = Enum.map(erl_logs, &Map.delete(&1, "time"))
    ex = Enum.map(ex_logs, &Map.delete(&1, "time"))

    assert ex == erl
  end

  defp check(user, id, :gate) do
    StatsigEx.check_gate(user, id)
    :statsig.check_gate(user, id)
  end

  defp check(user, id, :config) do
    StatsigEx.get_config(user, id)
    :statsig.get_config(user, id)
  end

  defp flush do
    # flush both
    :statsig.flush_sync()
    StatsigEx.flush()
  end
end
