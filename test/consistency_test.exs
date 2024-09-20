defmodule StatsigEx.ConsistencyTest do
  use ExUnit.Case
  import StatsigEx.TestGenerator
  import StatsigEx.PressureTest
  alias StatsigEx.Evaluator

  "test/data/rulesets_e2e_expected_results.json"
  |> Path.expand()
  |> File.read!()
  |> Jason.decode!()
  |> Map.get("data")
  |> generate_all_tests()

  test "random messages are properly handled" do
    assert :ok = Process.send(:test, {:ssl_closed, {:sslsocket, {:gen_tcp, :etc}}}, [])
    # give the server time to handle the message
    Process.sleep(100)
  end
end
