defmodule AshAi do
  @moduledoc """
  Documentation for `AshAi`.
  """

  alias LangChain.Chains.LLMChain

  defstruct []

  require Logger

  @full_text %Spark.Dsl.Section{
    name: :full_text,
    imports: [Ash.Expr],
    schema: [
      name: [
        type: :atom,
        default: :full_text_vector,
        doc: "The name of the attribute to store the text vector in"
      ],
      used_attributes: [
        type: {:list, :atom},
        doc: "If set, a vector is only regenerated when these attributes are changed"
      ],
      text: [
        type: {:fun, 1},
        required: true,
        doc:
          "A function or expr that takes a list of records and computes a full text string that will be vectorized. If given an expr, use `atomic_ref` to refer to new values, as this is set as an atomic update."
      ]
    ]
  }

  @vectorize %Spark.Dsl.Section{
    name: :vectorize,
    sections: [
      @full_text
    ],
    schema: [
      attributes: [
        type: :keyword_list,
        doc:
          "A keyword list of attributes to vectorize, and the name of the attribute to store the vector in",
        default: []
      ],
      strategy: [
        type: {:one_of, [:after_action]},
        default: :after_action,
        doc:
          "How to compute the vector. Only `after_action` is supported, but eventually `ash_oban` will be supported as well"
      ]
    ]
  }

  defmodule Tool do
    @moduledoc "An action exposed to LLM agents"
    defstruct [:name, :resource, :action, :domain]
  end

  @tool %Spark.Dsl.Entity{
    name: :tool,
    target: Tool,
    schema: [
      name: [type: :atom, required: true],
      resource: [type: {:spark, Ash.Resource}, required: true],
      action: [type: :atom, required: true]
    ],
    args: [:name, :resource, :action]
  }

  @tools %Spark.Dsl.Section{
    name: :tools,
    entities: [
      @tool
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@tools, @vectorize],
    imports: [AshAi.Actions],
    transformers: [AshAi.Transformers.Vectorize]

  defimpl Jason.Encoder, for: OpenApiSpex.Schema do
    def encode(value, opts) do
      OpenApiSpex.OpenApi.to_map(value) |> Jason.Encoder.Map.encode(opts)
    end
  end

  defmodule Options do
    use Spark.Options.Validator,
      schema: [
        actions: [
          type: {:wrap_list, {:tuple, [{:spark, Ash.Resource}, :atom]}},
          doc: """
          A set of {Resource, :action} pairs, or `{Resource, :*}` for all actions.
          """
        ],
        exclude_actions: [
          type: {:wrap_list, {:tuple, [{:spark, Ash.Resource}, :atom]}},
          doc: """
          A set of {Resource, :action} pairs, or `{Resource, :*}` to be excluded from the added actions.
          """
        ],
        actor: [
          type: :any,
          doc: "The actor performing any actions."
        ],
        messages: [
          type: {:list, :map},
          default: [],
          doc: """
          Used to provide conversation history.
          """
        ],
        otp_app: [
          type: :atom,
          doc: "If present, allows discovering resource actions automatically."
        ],
        system_prompt: [
          type: {:fun, 1},
          doc: """
          A system prompt that takes the provided options and returns a system prompt.

          You will want to include something like the actor's id if you are chatting as an
          actor.
          """
        ]
      ]
  end

  def functions(opts) do
    opts
    |> exposed_tools()
    |> Enum.map(fn tool ->
      function(tool.name, tool.domain, tool.resource, tool.action)
    end)
  end

  # def ask_about_actions_function(otp_app_or_actions) do
  # end

  def iex_chat(lang_chain, opts \\ []) do
    opts = Options.validate!(opts)

    messages =
      case opts.system_prompt do
        :none ->
          []

        nil ->
          [
            LangChain.Message.new_system!("""
            You are a helpful assistant.
            Your purpose is to operate the application on behalf of the user.
            """)
          ]

        system_prompt ->
          [LangChain.Message.new_system!(system_prompt)]
      end

    handler = %{
      on_llm_new_delta: fn _model, data ->
        # we received a piece of data
        IO.write(data.content)
      end,
      on_message_processed: fn _chain, _data ->
        # the message was assembled and is processed
        IO.write("\n--\n")
      end
    }

    lang_chain
    |> LLMChain.add_messages(messages)
    |> setup_ash_ai(opts)
    |> LLMChain.add_callback(handler)
    |> then(fn llm_chain ->
      if opts.actor do
        LLMChain.update_custom_context(llm_chain, %{actor: opts.actor})
      else
        llm_chain
      end
    end)
    |> run_loop(true)
  end

  @doc """
  Adds the requisite context and tool calls to allow an agent to interact with your app.


  """
  def setup_ash_ai(lang_chain, opts \\ []) do
    opts = Options.validate!(opts)

    tools = functions(opts)

    if Enum.count_until(tools, 32) == 32 do
      raise "can't do more than 32 tools right now"
      # TODO: select_and_execute_action()
    end

    lang_chain
    |> LLMChain.add_tools(tools)
  end

  defp run_loop(chain, first? \\ false) do
    chain
    |> LLMChain.run(mode: :while_needs_response)
    |> case do
      {:ok,
       %LangChain.Chains.LLMChain{
         last_message: %{content: content}
       } = new_chain} ->
        if !first? && !Map.get(new_chain.llm, :stream) do
          IO.puts(content)
        end

        user_message = Mix.shell().prompt("> ")

        new_chain
        |> LLMChain.add_messages([LangChain.Message.new_user!(user_message)])
        |> run_loop()

      {:error, error} ->
        raise "Something went wrong:\n #{Exception.format(:error, error)}"
    end
  end

  defp parameter_schema(_domain, resource, action) do
    AshJsonApi.OpenApi.write_attributes(
      resource,
      action.arguments,
      action,
      %{type: :action, route: "/"},
      :json
    )
    |> then(fn attrs ->
      %{
        type: :object,
        properties:
          %{
            input: %{
              type: :object,
              properties: attrs,
              required:
                AshJsonApi.OpenApi.required_write_attributes(resource, action.arguments, action)
            }
          }
          |> add_action_specific_properties(resource, action)
      }
    end)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp function(name, domain, resource, action) do
    name = to_string(name)

    description =
      action.description ||
        "Call the #{action.name} action on the #{inspect(resource)} resource"

    parameter_schema = parameter_schema(domain, resource, action)

    LangChain.Function.new!(%{
      name: name,
      description: description,
      parameters_schema: parameter_schema,
      function: fn arguments, context ->
        actor = context[:actor]

        try do
          case action.type do
            :read ->
              sort =
                case arguments["sort"] do
                  sort when is_list(sort) ->
                    Enum.map(sort, fn map ->
                      case map["direction"] || "asc" do
                        "asc" -> map["field"]
                        "desc" -> "-#{map["field"]}"
                      end
                    end)

                  nil ->
                    []
                end
                |> Enum.join(",")

              resource
              |> Ash.Query.limit(arguments["limit"] || 25)
              |> Ash.Query.offset(arguments["offset"])
              |> then(fn query ->
                if sort != "" do
                  Ash.Query.sort_input(query, sort)
                else
                  query
                end
              end)
              |> then(fn query ->
                if Map.has_key?(arguments, "filter") do
                  Ash.Query.filter_input(query, arguments["filter"])
                else
                  query
                end
              end)
              |> Ash.Query.for_read(action.name, arguments["input"] || %{},
                domain: domain,
                actor: actor
              )
              |> Ash.Actions.Read.unpaginated_read(action)
              |> case do
                {:ok, value} ->
                  value

                {:error, error} ->
                  raise Ash.Error.to_error_class(error)
              end
              |> then(fn result ->
                result
                |> AshJsonApi.Serializer.serialize_value({:array, resource}, [], domain)
                |> Jason.encode!()
                |> then(&{:ok, &1, result})
              end)

            :update ->
              pkey =
                Map.new(Ash.Resource.Info.primary_key(resource), fn key ->
                  {key, arguments[to_string(key)]}
                end)

              resource
              |> Ash.get!(pkey)
              |> Ash.Changeset.for_update(action.name, arguments["input"],
                domain: domain,
                actor: actor
              )
              |> Ash.update!()
              |> then(fn result ->
                result
                |> AshJsonApi.Serializer.serialize_value(resource, [], domain)
                |> Jason.encode!()
                |> then(&{:ok, &1, result})
              end)

            :destroy ->
              pkey =
                Map.new(Ash.Resource.Info.primary_key(resource), fn key ->
                  {key, arguments[to_string(key)]}
                end)

              resource
              |> Ash.get!(pkey)
              |> Ash.Changeset.for_destroy(action.name, arguments["input"],
                domain: domain,
                actor: actor
              )
              |> Ash.destroy!()
              |> then(fn result ->
                result
                |> AshJsonApi.Serializer.serialize_value(resource, [], domain)
                |> Jason.encode!()
                |> then(&{:ok, &1, result})
              end)

            :create ->
              resource
              |> Ash.Changeset.for_create(action.name, arguments["input"],
                domain: domain,
                actor: actor
              )
              |> Ash.create!()
              |> then(fn result ->
                result
                |> AshJsonApi.Serializer.serialize_value(resource, [], domain)
                |> Jason.encode!()
                |> then(&{:ok, &1, result})
              end)

            :action ->
              resource
              |> Ash.ActionInput.for_action(action.name, arguments["input"],
                domain: domain,
                actor: actor
              )
              |> Ash.run_action!()
              |> then(fn result ->
                if action.returns do
                  result
                  |> AshJsonApi.Serializer.serialize_value(action.returns, [], domain)
                  |> Jason.encode!()
                else
                  "success"
                end
                |> then(&{:ok, &1, result})
              end)
          end
        rescue
          error ->
            {:error,
             domain
             |> AshJsonApi.Error.to_json_api_errors(resource, error, action.type)
             |> serialize_errors()
             |> Jason.encode!()}
        end
      end
    })
  end

  def to_json_api_errors(domain, resource, errors, type) when is_list(errors) do
    Enum.flat_map(errors, &to_json_api_errors(domain, resource, &1, type))
  end

  def to_json_api_errors(domain, resource, %mod{errors: errors}, type)
      when mod in [Forbidden, Framework, Invalid, Unknown] do
    Enum.flat_map(errors, &to_json_api_errors(domain, resource, &1, type))
  end

  def to_json_api_errors(_domain, _resource, %AshJsonApi.Error{} = error, _type) do
    [error]
  end

  def to_json_api_errors(domain, _resource, %{class: :invalid} = error, _type) do
    if AshJsonApi.ToJsonApiError.impl_for(error) do
      error
      |> AshJsonApi.ToJsonApiError.to_json_api_error()
      |> List.wrap()
      |> Enum.flat_map(&with_source_pointer(&1, error))
    else
      uuid = Ash.UUID.generate()

      stacktrace =
        case error do
          %{stacktrace: %{stacktrace: v}} ->
            v

          _ ->
            nil
        end

      Logger.warning(
        "`#{uuid}`: AshJsonApi.Error not implemented for error:\n\n#{Exception.format(:error, error, stacktrace)}"
      )

      if AshJsonApi.Domain.Info.show_raised_errors?(domain) do
        [
          %AshJsonApi.Error{
            id: uuid,
            status_code: class_to_status(error.class),
            code: "something_went_wrong",
            title: "SomethingWentWrong",
            detail: """
            Raised error: #{uuid}

            #{Exception.format(:error, error, stacktrace)}"
            """
          }
        ]
      else
        [
          %AshJsonApi.Error{
            id: uuid,
            status_code: class_to_status(error.class),
            code: "something_went_wrong",
            title: "SomethingWentWrong",
            detail: "Something went wrong. Error id: #{uuid}"
          }
        ]
      end
    end
  end

  def to_json_api_errors(_domain, _resource, %{class: :forbidden} = error, _type) do
    [
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: class_to_status(error.class),
        code: "forbidden",
        title: "Forbidden",
        detail: "forbidden"
      }
    ]
  end

  def to_json_api_errors(_domain, _resource, error, _type) do
    uuid = Ash.UUID.generate()

    stacktrace =
      case error do
        %{stacktrace: %{stacktrace: v}} ->
          v

        _ ->
          nil
      end

    Logger.warning(
      "`#{uuid}`: AshJsonApi.Error not implemented for error:\n\n#{Exception.format(:error, error, stacktrace)}"
    )

    [
      %AshJsonApi.Error{
        id: uuid,
        status_code: class_to_status(error.class),
        code: "something_went_wrong",
        title: "SomethingWentWrong",
        detail: "Something went wrong. Error id: #{uuid}"
      }
    ]
  end

  @doc "Turns an error class into an HTTP status code"
  def class_to_status(:forbidden), do: 403
  def class_to_status(:invalid), do: 400
  def class_to_status(_), do: 500

  defp serialize_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.map(fn error ->
      %{}
      |> add_if_defined(:id, error.id)
      |> add_if_defined(:status, to_string(error.status_code))
      |> add_if_defined(:code, error.code)
      |> add_if_defined(:title, error.title)
      |> add_if_defined(:detail, error.detail)
      |> add_if_defined([:source, :pointer], error.source_pointer)
      |> add_if_defined([:source, :parameter], error.source_parameter)
      |> add_if_defined(:meta, parse_error(error.meta))
    end)
  end

  def with_source_pointer(%{source_pointer: source_pointer} = built_error, _)
      when source_pointer not in [nil, :undefined] do
    [built_error]
  end

  def with_source_pointer(built_error, %{fields: fields, path: path})
      when is_list(fields) and fields != [] do
    Enum.map(fields, fn field ->
      %{built_error | source_pointer: source_pointer(field, path)}
    end)
  end

  def with_source_pointer(built_error, %{field: field, path: path})
      when not is_nil(field) do
    [
      %{built_error | source_pointer: source_pointer(field, path)}
    ]
  end

  def with_source_pointer(built_error, _) do
    [built_error]
  end

  defp source_pointer(field, path) do
    "/input/#{Enum.join(List.wrap(path) ++ [field], "/")}"
  end

  defp add_if_defined(params, _, :undefined) do
    params
  end

  defp add_if_defined(params, [key1, key2], value) do
    params
    |> Map.put_new(key1, %{})
    |> Map.update!(key1, &Map.put(&1, key2, value))
  end

  defp add_if_defined(params, key, value) do
    Map.put(params, key, value)
  end

  defp parse_error(%{match: %Regex{} = match} = error) do
    %{error | match: Regex.source(match)}
  end

  defp parse_error(error), do: error

  defp add_action_specific_properties(properties, resource, %{type: :read}) do
    Map.merge(properties, %{
      filter: %{
        type: :object,
        description: "Filter results",
        # querying is complex, will likely need to be a two step process
        # i.e first decide to query, and then provide it with a function to call
        # that has all the options Then the filter object can be big & expressive.
        properties:
          Ash.Resource.Info.fields(resource, [:attributes, :calculations])
          |> Enum.filter(&(&1.public? && &1.filterable?))
          |> Enum.map(fn field ->
            {field.name, AshJsonApi.OpenApi.raw_filter_type(field, resource)}
          end)
          |> Enum.into(%{})
          |> Jason.encode!()
          |> Jason.decode!()
      },
      limit: %{
        type: :integer,
        description: "The maximum number of records to return",
        default: 25
      },
      offset: %{
        type: :integer,
        description: "The number of records to skip",
        default: 0
      },
      sort: %{
        type: :array,
        items: %{
          type: :object,
          properties:
            %{
              field: %{
                type: :string,
                description: "The field to sort by",
                enum:
                  Ash.Resource.Info.fields(resource, [
                    :attributes,
                    :calculations,
                    :aggregates
                  ])
                  |> Enum.filter(&(&1.public? && &1.sortable?))
                  |> Enum.map(& &1.name)
              },
              direction: %{
                type: :string,
                description: "The direction to sort by",
                enum: ["asc", "desc"]
              }
            }
            |> add_input_for_fields(resource)
        }
      }
    })
  end

  defp add_action_specific_properties(properties, resource, %{type: type})
       when type in [:update, :destroy] do
    pkey = Map.new(Ash.Resource.Info.primary_key(resource), fn key -> {key, %{type: :string}} end)

    Map.merge(properties, pkey)
  end

  defp add_action_specific_properties(properties, _resource, _action), do: properties

  defp add_input_for_fields(sort_obj, resource) do
    resource
    |> Ash.Resource.Info.fields([
      :calculations
    ])
    |> Enum.filter(&(&1.public? && &1.sortable? && !Enum.empty?(&1.arguments)))
    |> case do
      [] ->
        sort_obj

      fields ->
        input_for_fields =
          %{
            type: :object,
            additonalProperties: false,
            properties:
              Map.new(fields, fn field ->
                inputs =
                  Enum.map(field.arguments, fn argument ->
                    {argument.name,
                     AshJsonApi.OpenApi.resource_write_attribute_type(argument, :create)}
                  end)

                required =
                  Enum.flat_map(field.arguments, fn argument ->
                    if argument.allow_nil? do
                      []
                    else
                      [argument.name]
                    end
                  end)

                {field.name,
                 %{
                   type: :object,
                   properties: Map.new(inputs),
                   required: required,
                   additionalProperties: false
                 }}
              end)
          }

        Map.put(sort_obj, :input_for_fields, input_for_fields)
    end
  end

  @doc false
  def exposed_tools(opts) when is_list(opts) do
    exposed_tools(Options.validate!(opts))
  end

  def exposed_tools(opts) do
    if opts.actions do
      Enum.flat_map(opts.actions, fn
        {resource, actions} ->
          domain = Ash.Resource.Info.domain(resource)

          if !domain do
            raise "Cannot use an ash resource that does not have a domain"
          end

          tools = AshAi.Info.tools(domain)

          if !Enum.any?(AshAi.Info.tools(domain), fn tool ->
               tool.resource == resource && (actions == :* || tool.action in actions)
             end) do
            raise "Cannot use an action that is not exposed as a tool"
          end

          if actions == :* do
            tools
            |> Enum.filter(&(&1.resource == resource))
            |> Enum.map(fn tool ->
              %{tool | domain: domain, action: Ash.Resource.Info.action(resource, tool.action)}
            end)
          else
            tools
            |> Enum.filter(&(&1.resource == resource && &1.action in actions))
            |> Enum.map(fn tool ->
              %{tool | domain: domain, action: Ash.Resource.Info.action(resource, tool.action)}
            end)
          end
      end)
    else
      if !opts.otp_app do
        raise "Must specify `otp_app` if you do not specify `actions`"
      end

      for domain <- Application.get_env(opts.otp_app, :ash_domains) || [],
          tool <- AshAi.Info.tools(domain),
          action = Ash.Resource.Info.action(tool.resource, tool.action),
          can?(
            opts.actor,
            domain,
            tool.resource,
            action
          ) do
        %{tool | domain: domain, action: Ash.Resource.Info.action(tool.resource, tool.action)}
      end
    end
    |> Enum.uniq()
    |> then(fn tools ->
      if is_list(opts.exclude_actions) do
        Enum.reject(tools, fn tool ->
          {tool.resource, tool.action.name} in opts.exclude_actions
        end)
      else
        tools
      end
    end)
  end

  defp can?(actor, domain, resource, action) do
    Ash.can?({resource, action}, actor, domain: domain, maybe_is: true, run_queries?: false)
  end
end
