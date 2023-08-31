defmodule ElectricTest.SatelliteHelpers do
  use Electric.Satellite.Protobuf

  import ExUnit.Assertions

  alias Satellite.TestWsClient, as: MockClient

  def assert_receive_migration(conn, version, table_name) do
    assert_receive {^conn, %SatRelation{table_name: ^table_name}}

    assert_receive {^conn,
                    %SatOpLog{
                      ops: [
                        %{op: {:begin, %SatOpBegin{is_migration: true, lsn: lsn_str}}},
                        %{op: {:migrate, %{version: ^version, table: %{name: ^table_name}}}},
                        %{op: {:commit, _}}
                      ]
                    }}

    assert {lsn, ""} = Integer.parse(lsn_str)
    assert lsn > 0
  end

  def with_connect(opts, fun), do: MockClient.with_connect(opts, fun)

  defp migrate(conn, version, sql, opts \\ []) do
    # we need to explicitly capture ddl statements affecting electrified tables
    # unless we're connecting via the proxy
    electrify =
      if table = opts[:electrify], do: "CALL electric.electrify('#{table}')"

    capture =
      if opts[:capture], do: "CALL electric.capture_ddl($$#{sql}$$)"

    results =
      :epgsql.squery(
        conn,
        """
        BEGIN;
          CALL electric.migration_version('#{version}');
          #{sql};
          #{electrify};
          #{capture};
        COMMIT;
        """
      )

    Enum.each(results, fn result ->
      assert {:ok, _, _} = result
    end)

    :ok
  end
end
