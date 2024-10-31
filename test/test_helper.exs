Application.ensure_all_started(:statsig)
StatsigEx.start_link(name: :test, tier: :test_test)
ExUnit.start(exclude: [:flakey])
