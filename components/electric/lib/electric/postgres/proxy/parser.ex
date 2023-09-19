defmodule Electric.Postgres.Proxy.Parser.Macros do
  defmacro defkeyword(function, keyword, opts \\ [], do: block) do
    chars =
      keyword
      |> String.codepoints()
      |> Enum.map(fn char -> [String.downcase(char), String.upcase(char)] end)
      |> Enum.map(fn [<<l::8>>, <<u::8>>] -> [l, u] end)

    whitespace = if Keyword.get(opts, :trailing, true), do: [~c"\t\n\r "], else: []
    chars = Enum.with_index(chars ++ whitespace)
    pattern = build_match(chars)
    guards = build_guards(chars)

    quote do
      def unquote(function)(unquote(pattern) = var!(stmt)) when unquote(guards) do
        _ = var!(rest)
        _ = var!(stmt)
        unquote(block)
      end
    end
  end

  defp build_match(chars) do
    {:<<>>, [],
     Enum.map(chars, fn {_c, i} -> {:"::", [], [{:"c#{i}", [], Elixir}, 8]} end) ++
       [{:"::", [], [{:var!, [], [{:rest, [], Elixir}]}, {:binary, [], Elixir}]}]}
  end

  defp build_guards([{c, i}]) do
    {:in, [], [{:"c#{i}", [], Elixir}, c]}
  end

  defp build_guards([{c, i} | rest]) do
    {:and, [], [{:in, [], [{:"c#{i}", [], Elixir}, c]}, build_guards(rest)]}
  end
end

defmodule Electric.Postgres.Proxy.Parser do
  alias Electric.Postgres.Proxy.NameParser
  alias Electric.Postgres.Proxy.Injector
  alias Electric.Postgres.Extension.SchemaLoader

  import __MODULE__.Macros

  defmodule Analysis do
    defstruct [
      :action,
      :table,
      :ast,
      electrified?: false,
      allowed?: true,
      capture: false,
      errors: []
    ]
  end

  @default_schema "public"
  @wspc ~c"\t\n\r "

  def parse(sql) do
    with {:ok, ast} <- PgQuery.parse(sql) do
      {:ok, stmt(ast)}
    end
  end

  @spec table_name(binary() | struct(), Keyword.t()) :: {String.t(), String.t()} | nil | no_return
  def table_name(query, opts \\ [])

  def table_name(query, opts) when is_binary(query) do
    with {:ok, ast} <- parse(query) do
      table_name(ast, opts)
    end
  end

  def table_name(%{relation: %{schemaname: s, relname: n}}, opts) do
    {blank(s, opts), n}
  end

  # TODO: drop table supports a list of table names, but let's not support that for the moment
  def table_name(%PgQuery.DropStmt{objects: [object]} = _stmt, opts) do
    %{node: {:list, %{items: items}}} = object
    names = Enum.map(items, fn %{node: {:string, %{sval: n}}} -> n end)

    case names do
      [_tablespace, schema, table] ->
        {schema, table}

      [schema, table] ->
        {schema, table}

      [table] ->
        {blank(nil, opts), table}
    end
  end

  def table_name(
        %PgQuery.CallStmt{funccall: %{funcname: [func_schema, func_name]} = funccall},
        opts
      ) do
    case {string_node_val(func_schema), string_node_val(func_name)} do
      {"electric", "electrify"} ->
        case Enum.map(funccall.args, &string_node_val/1) do
          [a1, a2] ->
            {a1, a2}

          [a1] ->
            NameParser.parse!(a1, opts)
        end

      _ ->
        nil
    end
  end

  def table_name(_stmt, _opts) do
    nil
  end

  defp string_node_val(%PgQuery.Node{node: {:string, %PgQuery.String{sval: sval}}}), do: sval

  defp string_node_val(%PgQuery.Node{node: {:a_const, %PgQuery.A_Const{val: {:sval, sval}}}}),
    do: string_node_val(sval)

  defp string_node_val(%PgQuery.String{sval: sval}), do: sval

  #   enum AlterTableType
  # {
  #   ALTER_TABLE_TYPE_UNDEFINED = 0;
  #   AT_AddColumn = 1;
  #   AT_AddColumnRecurse = 2;
  #   AT_AddColumnToView = 3;
  #   AT_ColumnDefault = 4;
  #   AT_CookedColumnDefault = 5;
  #   AT_DropNotNull = 6;
  #   AT_SetNotNull = 7;
  #   AT_DropExpression = 8;
  #   AT_CheckNotNull = 9;
  #   AT_SetStatistics = 10;
  #   AT_SetOptions = 11;
  #   AT_ResetOptions = 12;
  #   AT_SetStorage = 13;
  #   AT_SetCompression = 14;
  #   AT_DropColumn = 15;
  #   AT_DropColumnRecurse = 16;
  #   AT_AddIndex = 17;
  #   AT_ReAddIndex = 18;
  #   AT_AddConstraint = 19;
  #   AT_AddConstraintRecurse = 20;
  #   AT_ReAddConstraint = 21;
  #   AT_ReAddDomainConstraint = 22;
  #   AT_AlterConstraint = 23;
  #   AT_ValidateConstraint = 24;
  #   AT_ValidateConstraintRecurse = 25;
  #   AT_AddIndexConstraint = 26;
  #   AT_DropConstraint = 27;
  #   AT_DropConstraintRecurse = 28;
  #   AT_ReAddComment = 29;
  #   AT_AlterColumnType = 30;
  #   AT_AlterColumnGenericOptions = 31;
  #   AT_ChangeOwner = 32;
  #   AT_ClusterOn = 33;
  #   AT_DropCluster = 34;
  #   AT_SetLogged = 35;
  #   AT_SetUnLogged = 36;
  #   AT_DropOids = 37;
  #   AT_SetAccessMethod = 38;
  #   AT_SetTableSpace = 39;
  #   AT_SetRelOptions = 40;
  #   AT_ResetRelOptions = 41;
  #   AT_ReplaceRelOptions = 42;
  #   AT_EnableTrig = 43;
  #   AT_EnableAlwaysTrig = 44;
  #   AT_EnableReplicaTrig = 45;
  #   AT_DisableTrig = 46;
  #   AT_EnableTrigAll = 47;
  #   AT_DisableTrigAll = 48;
  #   AT_EnableTrigUser = 49;
  #   AT_DisableTrigUser = 50;
  #   AT_EnableRule = 51;
  #   AT_EnableAlwaysRule = 52;
  #   AT_EnableReplicaRule = 53;
  #   AT_DisableRule = 54;
  #   AT_AddInherit = 55;
  #   AT_DropInherit = 56;
  #   AT_AddOf = 57;
  #   AT_DropOf = 58;
  #   AT_ReplicaIdentity = 59;
  #   AT_EnableRowSecurity = 60;
  #   AT_DisableRowSecurity = 61;
  #   AT_ForceRowSecurity = 62;
  #   AT_NoForceRowSecurity = 63;
  #   AT_GenericOptions = 64;
  #   AT_AttachPartition = 65;
  #   AT_DetachPartition = 66;
  #   AT_DetachPartitionFinalize = 67;
  #   AT_AddIdentity = 68;
  #   AT_SetIdentity = 69;
  #   AT_DropIdentity = 70;
  #   AT_ReAddStatistics = 71;
  # }

  def is_additive_migration(query) when is_binary(query) do
    with {:ok, ast} <- parse(query) do
      case ast do
        %PgQuery.AlterTableStmt{} ->
          {:ok, Enum.all?(ast.cmds, &is_additive_migration_cmd/1)}

        %PgQuery.RenameStmt{} ->
          {:ok, false}

        _ ->
          {:error, "not an alter table statement #{inspect(query)}"}
      end
    end
  end

  # there are alter table commands that we support: add column
  # there are those we dont support, e.g. drop column
  # and those we couldn't care less about, e.g. AT_ReAddStatistics
  # for the moment the ignorable ones will raise an error because they're
  # fairly niche IMHO
  @additive_cmds [:AT_AddColumn, :AT_AddColumnRecurse]

  defp is_additive_migration_cmd(%{node: {:alter_table_cmd, cmd}}) do
    cmd.subtype in @additive_cmds
  end

  def column_map(sql) when is_binary(sql) do
    with {:ok, ast} <- parse(sql) do
      column_map(ast)
    end
  end

  def column_map(%PgQuery.InsertStmt{} = ast) do
    cols =
      ast.cols
      |> Enum.map(fn %{node: {:res_target, %{name: name}}} -> name end)
      |> Enum.with_index()
      |> Enum.into(%{})

    {:ok, cols}
  end

  def column_map(ast) do
    {:error, "Not an INSERT statement: #{inspect(ast)}"}
  end

  def column_values_map(%PgQuery.InsertStmt{} = ast) do
    {:ok, column_map} = column_map(ast)

    names =
      column_map
      |> Enum.sort_by(fn {_name, index} -> index end, :asc)
      |> Enum.map(&elem(&1, 0))

    %{select_stmt: %{node: {:select_stmt, select}}} = ast
    %{values_lists: [%{node: {:list, %{items: column_values}}}]} = select

    values = Enum.map(column_values, fn %{node: {:a_const, %{val: val}}} -> decode_val(val) end)

    {:ok, Map.new(Enum.zip(names, values))}
  end

  defp decode_val({:sval, %{sval: s}}), do: s
  defp decode_val({:fval, %{fval: s}}), do: String.to_integer(s)

  defp stmt(%PgQuery.ParseResult{version: _, stmts: [raw_stmt | _]}) do
    %PgQuery.RawStmt{stmt: %PgQuery.Node{node: {_tag, stmt}}} = raw_stmt

    stmt
  end

  defp blank(e, opts) when e in [nil, ""] do
    Keyword.get(opts, :default_schema, @default_schema)
  end

  defp blank(e, _), do: e

  def insert?(<<w::8, rest::binary>>) when w in @wspc and byte_size(rest) > 6 do
    insert?(rest)
  end

  defkeyword :insert?, "INSERT" do
    true
  end

  def insert?(_), do: false

  def capture?(<<w::8, rest::binary>>) when w in @wspc do
    capture?(rest)
  end

  defkeyword :capture?, "BEGIN", trailing: false do
    {true, :begin}
  end

  defkeyword :capture?, "ALTER" do
    case object(rest) do
      "table" ->
        {true, {:alter, "table"}}

      _other ->
        false
    end
  end

  defkeyword :capture?, "CREATE" do
    case object(rest) do
      "table" ->
        false

      "index" ->
        {true, {:create, "index"}}

      _other ->
        false
    end
  end

  defkeyword :capture?, "DROP" do
    case object(rest) do
      "index" ->
        {true, {:drop, "index"}}

      "table" ->
        {true, {:drop, "table"}}

      _other ->
        false
    end
  end

  defkeyword :capture?, "COMMIT", trailing: false do
    {true, :commit}
  end

  defkeyword :capture?, "ROLLBACK", trailing: false do
    {true, :rollback}
  end

  defkeyword :capture?, "ELECTRIC" do
    # we absorb the :error/:ok because errors return a %Command.Error{}
    {_, command} = ddlx(rest)
    {true, {:electric, command}}
  end

  defkeyword :capture?, "CALL" do
    {true, {:call, "electrify"}}
  end

  def capture?(_stmt) do
    false
  end

  defp ddlx(stmt) do
    Electric.DDLX.Parse.Parser.parse("ELECTRIC " <> stmt)
  end

  def object(<<w::8, rest::binary>>) when w in @wspc do
    object(rest)
  end

  defkeyword :object, "TABLE" do
    "table"
  end

  defkeyword :object, "INDEX" do
    "index"
  end

  def electric_electrify(<<w::8, rest::binary>>) when w in @wspc do
    electric_electrify(rest)
  end

  def electric_electrify("electric.electrify(" <> _rest), do: true
  def electric_electrify(_), do: false

  @split_ws Enum.map(@wspc, &IO.iodata_to_binary([&1]))
  def object(other) do
    [type, _rest] = :binary.split(other, @split_ws)
    String.downcase(type)
  end

  def table_modifications(sql) when is_binary(sql) do
    sql
    |> Electric.Postgres.parse!()
    |> Enum.flat_map(&analyse_modifications_query/1)
  end

  defp analyse_modifications_query(%PgQuery.AlterTableStmt{} = stmt) do
    {:ok, {_schema, _name} = table} = table_name(stmt)

    Enum.map(stmt.cmds, fn %{node: {:alter_table_cmd, cmd}} ->
      Map.new([{:action, modification_action(cmd)}, {:table, table} | column_definition(cmd.def)])
    end)
  end

  # we're currently only interested in alter table statements
  defp analyse_modifications_query(_stmt) do
    []
  end

  defp modification_action(%{subtype: :AT_AddColumn}), do: :add
  defp modification_action(%{subtype: :AT_DropColumn}), do: :drop
  defp modification_action(_), do: :modify

  defp column_definition(%{node: {:column_def, def}}) do
    [column: def.colname, type: Electric.Postgres.Dialect.Postgresql.map_type(def.type_name)]
  end

  defp column_definition(nil) do
    []
  end

  def analyse(query, loader) when is_binary(query) do
    query
    |> Electric.Postgres.parse!()
    |> Enum.flat_map(&analyse_stmt(&1, loader))
  end

  defp analyse_stmt(stmt, loader) do
    table = table_name(stmt)

    analysis = %Analysis{
      table: table,
      electrified?: is_electrified?(table, loader),
      ast: stmt
    }

    analyse_stmt(stmt, analysis, loader)
  end

  defp analyse_stmt(%PgQuery.AlterTableStmt{} = stmt, analysis, loader) do
    stmt.cmds
    |> Enum.map(&unwrap_node/1)
    |> Enum.map(&analyse_alter_table_cmd(&1, %{analysis | action: {:alter, "table"}}, loader))
  end

  defp analyse_stmt(%PgQuery.TransactionStmt{} = stmt, analysis, loader) do
    kind =
      case stmt.kind do
        :TRANS_STMT_BEGIN -> :begin
        :TRANS_STMT_COMMIT -> :commit
      end

    [%{analysis | action: kind}]
  end

  defp analyse_stmt(%PgQuery.CreateStmt{}, analysis, loader) do
    [%{analysis | action: {:create, "table"}}]
  end

  defp analyse_alter_table_cmd(cmd, %{electrified?: false} = analysis, loader) do
    analysis
  end

  defp analyse_alter_table_cmd(%{subtype: :AT_AddColumn} = cmd, analysis, _loader) do
    column_def = unwrap_node(cmd.def)

    case check_column_type(column_def) do
      :ok ->
        %{analysis | capture: true}

      {:error, reason} ->
        %{analysis | allowed?: false, errors: [reason | analysis.errors]}
    end
  end

  defp analyse_alter_table_cmd(%{subtype: :AT_DropColumn} = cmd, analysis, _loader) do
    %{analysis | allowed?: false, errors: [{:drop_column, cmd.name} | analysis.errors]}
  end

  defp is_electrified?(nil, _loader) do
    false
  end

  defp is_electrified?(table, loader) do
    {:ok, electrified?} = SchemaLoader.table_electrified?(loader, table)
    electrified?
  end

  @valid_types for t <- Electric.Satellite.Serialization.supported_pg_types(), do: to_string(t)

  defp check_column_type(%PgQuery.ColumnDef{} = coldef) do
    %{name: type} = Electric.Postgres.Schema.AST.map(coldef.type_name)

    if type in @valid_types do
      :ok
    else
      {:error, {:invalid_column_type, type}}
    end
  end

  defp unwrap_node(%PgQuery.Node{node: {_type, node}}), do: node
end
