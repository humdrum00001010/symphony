ExUnit.start()
{:ok, _registry} = Registry.start_link(keys: :unique, name: Symphony.Processes)
