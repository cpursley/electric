defmodule Electric.Postgres.Proxy.InjectorTest do
  use ExUnit.Case, async: true

  alias Electric.Postgres.Proxy.Injector
  alias Electric.Postgres.Proxy.TestScenario

  @moduletag capture_log: true

  setup do
    migrations = [
      {"0001",
       [
         "CREATE TABLE public.truths (id uuid PRIMARY KEY, value text)",
         "CREATE INDEX truths_idx ON public.truths (value)"
       ]}
    ]

    {module, opts} = Electric.Postgres.MockSchemaLoader.backend_spec(migrations: migrations)

    {:ok, conn} =
      module.connect([], opts)

    {:ok, injector} =
      Injector.new(loader: {module, conn}, injector: TestScenario.MockInjector)

    version = System.system_time(:microsecond)
    timestamp = DateTime.utc_now()

    {:ok, injector: injector, version: version, timestamp: timestamp}
  end

  @scenarios [
    TestScenario.FrameworkSimple,
    TestScenario.Framework,
    TestScenario.Manual,
    TestScenario.AdHoc,
    TestScenario.ManualTx
  ]

  for s <- @scenarios do
    describe s.description() do
      @describetag s.tags()

      setup do
        {:ok, scenario: unquote(s)}
      end

      test "create table is not captured", cxt do
        query = ~s[CREATE TABLE "truths" ("another" int8)]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      # unless the scenario has client-generated transactions
      # this situation is impossible
      if s.tx?() do
        test "create, electrify and alter table is captured", cxt do
          queries = [
            passthrough: ~s[CREATE TABLE "socks" ("id" uuid PRIMARY KEY, colour TEXT)],
            electric: ~s[ALTER TABLE "socks" ENABLE ELECTRIC],
            capture: ~s[ALTER TABLE "socks" ADD COLUMN size int2]
          ]

          cxt.scenario.assert_electrified_migration(cxt.injector, queries)
        end
      end

      test "alter electrified table", cxt do
        query = ~s[ALTER TABLE "truths" ADD COLUMN "another" int8]

        cxt.scenario.assert_electrified_migration(cxt.injector, query)
      end

      test "alter non-electrified table does not inject", cxt do
        query = ~s[ALTER TABLE "underwear" ADD COLUMN "dirty" bool DEFAULT false]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      test "create index on electrified table is captured", cxt do
        query = ~s[CREATE INDEX "truths_idx" ON "truths" (value)]

        cxt.scenario.assert_electrified_migration(cxt.injector, query)
      end

      test "create index on non-electrified table is ignored", cxt do
        query = ~s[CREATE INDEX "underwear_idx" ON "underwear" (dirty)]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      test "drop electrified table raises error", cxt do
        query = ~s[DROP TABLE "truths"]

        cxt.scenario.assert_injector_error(cxt.injector, query,
          message: "Cannot DROP Electrified table \"public\".\"truths\"",
          detail: "Electric currently only supports additive migrations (ADD COLUMN, ADD INDEX)",
          schema: "public",
          table: "truths"
        )
      end

      test "drop non-electrified table is allowed", cxt do
        query = ~s[DROP TABLE "underwear"]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      test "drop column on electrified table raises error", cxt do
        query = ~s[ALTER TABLE "truths" DROP "value"]

        cxt.scenario.assert_injector_error(cxt.injector, query,
          message:
            "Invalid destructive migration on Electrified table \"public\".\"truths\": ALTER TABLE \"truths\" DROP \"value\"",
          detail: "Electric currently only supports additive migrations (ADD COLUMN, ADD INDEX)",
          schema: "public",
          table: "truths"
        )
      end

      test "drop column on non-electrified table is allowed", cxt do
        query = ~s[ALTER TABLE "underwear" DROP COLUMN "dirty"]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      test "rename column on electrified table raises error", cxt do
        query = ~s[ALTER TABLE "truths" RENAME "value" TO "worthless"]

        cxt.scenario.assert_injector_error(cxt.injector, query,
          message:
            "Invalid destructive migration on Electrified table \"public\".\"truths\": ALTER TABLE \"truths\" RENAME \"value\" TO \"worthless\"",
          detail: "Electric currently only supports additive migrations (ADD COLUMN, ADD INDEX)",
          schema: "public",
          table: "truths"
        )
      end

      test "rename column on non-electrified table is allowed", cxt do
        query = ~s[ALTER TABLE "underwear" RENAME COLUMN "dirty" TO "clean"]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      test "drop index on electrified table is captured", cxt do
        query = ~s[DROP INDEX "truths_idx"]

        cxt.scenario.assert_electrified_migration(cxt.injector, query)
      end

      test "drop index on non-electrified table is ignored", cxt do
        query = ~s[DROP INDEX "underwear_idx"]

        cxt.scenario.assert_non_electrified_migration(cxt.injector, query)
      end

      test "ALTER TABLE .. ENABLE ELECTRIC", cxt do
        query = ~s[ALTER TABLE "underwear" ENABLE ELECTRIC]

        cxt.scenario.assert_valid_electric_command(cxt.injector, query)
      end

      test "ELECTRIC REVOKE UPDATE", cxt do
        query = ~s[ELECTRIC REVOKE UPDATE (status, name) ON truths FROM 'projects:house.admin';]

        cxt.scenario.assert_valid_electric_command(cxt.injector, query)
      end

      test "invalid electric command", cxt do
        query = "ELECTRIC GRANT JUNK ON thing.Köln_en$ts TO 'projects:house.admin'"

        cxt.scenario.assert_injector_error(cxt.injector, query,
          code: "00000",
          detail: "Something went wrong near JUNK",
          line: 1,
          message: "Invalid ELECTRIC statement",
          query: "ELECTRIC GRANT JUNK ON thing.Köln_en$ts TO 'projects:house.admin'"
        )
      end

      test "errors from functions are correctly handled", cxt do
        # if you ran this the `electrify` function errors
        query = ~s[ALTER TABLE truths ENABLE ELECTRIC]

        cxt.scenario.assert_electrify_server_error(cxt.injector, query,
          message: "table truths already electrified"
        )
      end
    end
  end
end