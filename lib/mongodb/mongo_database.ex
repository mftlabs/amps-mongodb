# Copyright 2022 Agile Data, Inc <code@mftlabs.io>

defimpl Jason.Encoder, for: BSON.ObjectId do
  def encode(val, _opts \\ []) do
    BSON.ObjectId.encode!(val)
    |> Jason.encode!()
  end
end

defimpl Poison.Encoder, for: BSON.ObjectId do
  def encode(id, options) do
    BSON.ObjectId.encode!(id) |> Poison.Encoder.encode(options)
  end
end

defmodule AmpsDatabase do
  def aggregate_field(collection, field) do
    Amps.DB.aggregate_field(collection, field)
  end

  def get_user(user) do
    Amps.DB.find_one("user", %{"name" => user})
  end

  def get_action(action) do
    Amps.DB.find_one("actions", %{"name" => action})
  end

  def get_action_parms(action_id) do
    Amps.DB.find_one("actions", %{"_id" => action_id})
  end

  def get_itinerary(itname) do
    Amps.DB.find_one("itinerary", %{"name" => itname})
  end

  def get_rules(user) do
    Amps.DB.find_one("rule", %{"name" => user})
  end

  def get_config(name) do
    Amps.DB.find_one("services", %{"name" => name})
  end

  def get_config_filter(filter) do
    Amps.DB.find("services", filter)
  end
end

defmodule Amps.DB do
  @behaviour Database.Behaviour

  require Logger

  def get_db() do
    case Application.get_env(:amps, :db) do
      "mongo" ->
        {Mongo,
         [
           name: :mongo,
           database: "amps",
           url: Application.fetch_env!(:amps, :mongo_addr),
           pool_size: 15
         ]}

      "os" ->
        {Amps.Cluster, []}
    end
  end

  @impl true
  def aggregate_field(collection, field) do
    case Mongo.distinct(:mongo, collection, field, %{}) do
      {:ok, vals} ->
        vals

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def get_page(collection, id, clauses, sort) do
    obj = Mongo.find_one(:mongo, collection, %{"_id" => id})
    clauses = MongoFilter.parse(clauses)

    #      IO.inspect(clauses)

    sort =
      Enum.reduce(sort, %{}, fn {k, v}, acc ->
        dir =
          if v == "ASC" do
            1
          else
            -1
          end

        {k, dir, Map.put(acc, k, dir)}
      end)

    case sort do
      {field, dir, sort} ->
        dir =
          if dir == 1 do
            "$lt"
          else
            "$gt"
          end

        countclause =
          if clauses[field] do
            Map.put(
              clauses,
              field,
              Map.merge(clauses[field], %{
                dir => obj[field]
              })
            )
          else
            Map.put(clauses, field, %{
              dir => obj[field]
            })
          end

        {:ok, count} =
          Mongo.count_documents(
            :mongo,
            collection,
            countclause,
            sort: sort
          )

        IO.inspect(count)

        page = ceil((count + 1) / 25)

        num = rem(count, 25)

        cursor =
          Mongo.find(
            :mongo,
            collection,
            clauses,
            sort: sort,
            limit: 25,
            skip: (page - 1) * 25
          )

        data =
          cursor
          |> Enum.to_list()

        exists = Enum.at(data, num)["_id"] == id

        if exists do
          {:ok, page}
        else
          {:error, "Dynamic Data"}
        end

      _ ->
        {:error, "Not Sorting"}
    end
  end

  @impl true
  def add_to_field(collection, body, id, field) do
    fieldid = :uuid.uuid_to_string(:uuid.get_v4(), :binary_nodash)
    body = Map.put(body, "_id", fieldid)

    {:ok, _result} =
      Mongo.update_one(
        :mongo,
        collection,
        %{"_id" => id},
        %{"$push": %{field => body}}
      )

    new =
      Mongo.find_one(
        :mongo,
        collection,
        %{"_id" => id},
        projection: %{field => true}
      )

    {fieldid, new}
  end

  @impl true
  def find_one(collection, clauses, opts \\ %{}) do
    preparedFilter = MongoFilter.parse(clauses)
    opts = build_opts(opts)

    Mongo.find_one(:mongo, collection, preparedFilter, opts)
  end

  @impl true
  def get_in_field(collection, id, field, fieldid) do
    result =
      Mongo.find_one(
        :mongo,
        collection,
        %{"_id" => id}
      )

    Enum.find(result[field], fn obj ->
      obj["_id"] == fieldid
    end)
  end

  @impl true
  def update_in_field(collection, body, id, field, fieldid) do
    curr = get_in_field(collection, id, field, fieldid)
    new = Map.merge(curr, body)

    {:ok, _result} =
      Mongo.update_one(
        :mongo,
        collection,
        %{"_id" => id, (field <> "._id") => fieldid},
        %{
          "$set": %{(field <> ".$") => new}
        }
      )

    Mongo.find_one(:mongo, collection, %{"_id" => id})
  end

  @impl true
  def delete_from_field(collection, id, field, fieldid) do
    {:ok, _result} =
      Mongo.update_one(
        :mongo,
        collection,
        %{"_id" => id},
        %{
          "$pull": %{field => %{"_id" => fieldid}}
        }
      )

    Mongo.find_one(:mongo, collection, %{"_id" => id})
  end

  @impl true
  def insert(collection, body) do
    id = :uuid.uuid_to_string(:uuid.get_v4(), :binary_nodash)
    body = Map.put(body, "_id", id)

    case Mongo.insert_one(:mongo, collection, body) do
      {:error, error} ->
        {:error, error}

      {:ok, _result} ->
        {:ok, id}
    end
  end

  @impl true
  def delete(collection, clauses) do
    case Mongo.delete_many(:mongo, collection, clauses) do
      {:ok, result} ->
        {:ok, result.deleted_count}

      {:error, error} ->
        error
    end
  end

  @impl true
  def delete_one(collection, clauses) do
    case Mongo.delete_one(:mongo, collection, clauses) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  def build_opts(query) do
    sort =
      if query["sort"] != nil do
        query["sort"]
      else
        %{}
      end

    fields =
      if query["fields"] do
        query["fields"]
      else
        nil
      end

    projection =
      if fields do
        Enum.reduce(fields, %{}, fn field, proj ->
          Map.put(proj, field, 1)
        end)
      else
        nil
      end

    [
      sort: sort,
      limit: query["limit"],
      skip: query["start"],
      projection: projection
    ]
  end

  @impl true
  def get_rows(collection, query) do
    filters =
      if query["filters"] != nil do
        query["filters"]
      else
        %{}
      end

    preparedFilter = MongoFilter.parse(filters)
    opts = build_opts(query)
    cursor = Mongo.find(:mongo, collection, preparedFilter, opts)

    data =
      cursor
      |> Enum.to_list()

    count = Mongo.count_documents!(:mongo, collection, preparedFilter)

    %{rows: data, success: true, count: count}
  end

  @impl true
  def update(collection, body, id) do
    body = Map.drop(body, ["_id"])

    case Mongo.update_one(
           :mongo,
           collection,
           %{"_id" => id},
           %{"$set": body}
         ) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def delete_index(pattern) do
    Mongo.show_collections(:mongo)
    |> Enum.each(fn collection ->
      if Regex.match?(Regex.compile!(pattern), collection) do
        Mongo.drop_collection(:mongo, collection)
      end
    end)
  end

  @impl true
  def add_to_field_with_id(collection, body, id, field, fieldid) do
    body = Map.put(body, "_id", fieldid)

    {:ok, _result} =
      Mongo.update_one(
        :mongo,
        collection,
        %{"_id" => id},
        %{"$push": %{field => body}}
      )

    new = Mongo.find_one(:mongo, collection, %{"_id" => id}, projection: %{field => true})
    {fieldid, new}
  end

  @impl true
  def bulk_insert(doc) do
    id = :uuid.uuid_to_string(:uuid.get_v4(), :binary_nodash)

    doc =
      if doc[:level] != nil do
        Map.put(doc, :_id, id)
      else
        Map.put(doc, "_id", id)
      end

    case Mongo.BulkOps.get_insert_one(doc) do
      {:insert, [{:error, error}]} ->
        {:error, error}

      other ->
        other
    end
  end

  def bulk_update(clauses, doc) do
    case Mongo.BulkOps.get_update_one(clauses, doc) do
      {:update, [{:error, error}]} ->
        {:error, error}

      other ->
        other
    end
  end

  @impl true
  def bulk_perform(ops, index) do
    Mongo.UnorderedBulk.write(ops, :mongo, index, 1000) |> Stream.run()
  end

  @impl true
  def find_one_and_update(collection, clauses, body) do
    Mongo.find_one_and_update(:mongo, collection, clauses, %{"$set": body})
  end

  @impl true
  def delete_by_id(collection, id) do
    delete_one(collection, %{"_id" => id})
  end

  @impl true
  def find(collection, clauses \\ %{}, opts \\ %{}) do
    clauses = MongoFilter.parse(clauses)
    opts = build_opts(opts)
    cursor = Mongo.find(:mongo, collection, clauses, opts)
    cursor |> Enum.to_list()
  end

  @impl true
  def find_by_id(collection, id, opts \\ []) do
    Mongo.find_one(:mongo, collection, %{"_id" => id}, opts)
  end

  @impl true
  def insert_with_id(collection, body, id) do
    case Mongo.replace_one(:mongo, collection, %{"_id" => id}, body, upsert: true) do
      {:ok, _result} ->
        {:ok, id}

      {:error, err} ->
        {:error, err}
    end
  end
end

defmodule MongoFilter do
  def convert_dates(map, acc) do
    cond do
      is_map(map) ->
        cond do
          is_struct(map) ->
            map

          Map.has_key?(map, "$date") ->
            # with {:ok, datetime, _} <- DateTime.from_iso8601(Map.get(map, "$date")), do: datetime
            Map.get(map, "$date")

          # Map.has_key?(map, "$regex") ->
          #   %BSON.Regex{pattern: Map.get(map, "$regex")}
          true ->
            Enum.reduce(map, acc, fn {key, value}, acc ->
              Map.put(acc, key, convert_dates(value, acc))
            end)
        end

      true ->
        map
    end
  end

  def convert_dates(map) do
    cond do
      Map.has_key?(map, "$or") ->
        handle_cond(map, "$or")

      Map.has_key?(map, "$and") ->
        handle_cond(map, "$and")

      true ->
        acc = %{}
        convert_dates(map, acc)
    end
  end

  def handle_cond(map, op) do
    conds = Map.get(map, op)

    list =
      Enum.reduce(conds, [], fn element, acc ->
        [convert_dates(element) | acc]
      end)

    %{op => list}
  end

  def parse(filter) do
    if filter != nil do
      Enum.reduce(filter, %{}, fn {key, value}, acc ->
        Map.merge(acc, convert_dates(%{key => value}))
      end)
    else
      %{}
    end
  end

  def get_mongo_filter(filter) do
    case filter["operator"] do
      "like" ->
        %{filter["property"] => %{"$regex" => filter["value"]}}

      _ ->
        op = "$" <> filter["operator"]
        value = convert_sencha_dates(filter["value"])
        %{filter["property"] => %{op => value}}
    end
  end

  def convert_sencha_dates(value) do
    if Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, "#{value}") do
      pieces = String.split(value, "/")

      date =
        Date.from_iso8601!(
          Enum.at(pieces, 2) <>
            "-" <> Enum.at(pieces, 0) <> "-" <> Enum.at(pieces, 1)
        )

      {:ok, time} = Time.new(0, 0, 0, 0)
      DateTime.new!(date, time)
    else
      value
    end
  end

  def combine_filters(curr, new) do
    op = "$" <> new["operator"]
    value = convert_sencha_dates(new["value"])
    filters = Map.merge(curr, %{op => value})
    Map.put(%{}, new["property"], filters)
  end

  def convert_sencha_filter(filters) do
    Enum.reduce(filters, %{}, fn val, acc ->
      if Map.has_key?(acc, val["property"]) do
        combined = combine_filters(acc[val["property"]], val)
        Map.drop(acc, [val["property"]])
        Map.merge(acc, combined)
      else
        Map.merge(acc, get_mongo_filter(val))
      end
    end)
  end
end
