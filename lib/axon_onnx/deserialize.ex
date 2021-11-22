defmodule AxonOnnx.Deserialize do
  alias Onnx.ModelProto, as: Model
  alias Onnx.GraphProto, as: Graph
  alias Onnx.ValueInfoProto, as: Value
  alias Onnx.AttributeProto, as: Attribute
  alias Onnx.NodeProto, as: Node
  alias Onnx.TypeProto, as: Type
  alias Onnx.TensorProto, as: Tensor
  alias Onnx.TypeProto.Tensor, as: Placeholder
  alias Onnx.TensorShapeProto, as: Shape
  alias Onnx.TensorShapeProto.Dimension, as: Dimension

  # TODO(seanmor5): Currently we do a lot of potentially expensive operations
  # eagerly (especially when manipulating parameters), we can potentially make
  # them part of the model or alternatively return an initialization function
  # which can be JIT-compiled.

  # TODO(seanmor5): The current approach builds a lot of intermediate graphs,
  # instead we should only keep graphs which are specified as outputs and override
  # all other graphs so they are GC'ed

  # TODO(seanmor5): Some operations occur strictly on parameters (e.g. reshape, unsqueeze,
  # etc.), so we need to change all of these cases to handle instances where the only
  # input is a parameter which is an Nx expression rather than a model

  # TODO(seanmor5): Because some operations act on parameter inputs which don't have a
  # parameterized equivalent operation in Axon (e.g. add, multiply, etc.), we need
  # a way to implement them that still builds an Axon model but preserves the parameters

  # TODO(seanmor5): Because there are multiple versions of the protocol, there are also
  # multiple versions of each function. It's not that unreasonable to try to support every
  # version, but it just makes for a lot of annoying edge cases. Standardize around a minimum
  # supported version for guaranteed compatibility

  def __import__(file, opts \\ []) do
    file
    |> File.read!()
    |> Model.decode!()
    |> to_axon(opts)
  end

  defp to_axon(%Model{graph: %Graph{node: nodes} = graph}, opts) do
    dimensions = opts[:dimensions] || []
    dimensions = Enum.map(dimensions, &Atom.to_string/1)

    # IO.puts "Graph:\n\n"
    # IO.inspect graph

    params = get_params(graph)
    # IO.puts "Params:\n\n"
    # IO.inspect params

    # raise "Stop execution after obtaining params"
    inputs = get_inputs(graph, params, dimensions)
    # IO.puts "inputs >>>"
    # IO.inspect inputs
    outputs = get_outputs(graph)
    {nodes, params} = get_nodes(nodes, inputs, params, %{})
    {hd(Enum.map(outputs, fn name -> nodes[name] end)), params}
  end

  @spec decode_shape(list) :: tuple
  defp decode_shape(encoded_shape) do
    # IO.inspect encoded_shape
    List.to_tuple(
      case encoded_shape do # Tuple.to_list(shape) do
        [-1 | non_batch_size_dimensions] -> [nil | non_batch_size_dimensions]
        input_shape_with_constant_batch_size -> input_shape_with_constant_batch_size
      end
    )
  end

  defp get_inputs(%Graph{input: inputs}, params, dimensions) do
    Enum.reduce(inputs, %{}, fn %Value{name: name, type: %Type{value: value}}, acc ->
      if Map.has_key?(params, name) do
        # IO.puts "exisiting input"
        # IO.inspect acc, structs: false
        acc
      else
        case value do
          {:tensor_type, %Placeholder{} = tensor} ->
            input_shape = 
              shape!(tensor, dimensions)
              |> decode_shape
            
            # shape!(tensor, dimensions) |> IO.inspect
            # input_shape |> IO.inspect
            # {-1, remainder} = input_shape
            # remainder |> IO.inspect

            input_shape =
              if tuple_size(input_shape) == 1,
                do: Tuple.insert_at(input_shape, 0, nil),
                else: input_shape

                # IO.puts "missing input"
                Map.put(acc, name, Axon.input(input_shape))
                # IO.inspect input_shape
                # Axon.input(input_shape) |> IO.inspect structs: false

              # raise "Stop execution after creating an input node"

          _ ->
            raise ArgumentError, "unsupported input type"
        end
      end
    end)
  end

  defp get_params(%Graph{initializer: initializer} = graph) do
    # IO.inspect graph
    Enum.reduce(initializer, %{}, fn %Tensor{name_prefix: layer, name_suffix: name} = tensor, params ->
      value = tensor!(tensor)
      Map.put(
        params,
        layer,
        case params[layer] do
          nil -> %{name => value}
          layer_params -> Map.put(layer_params, name, value)
        end
      )
    end)
  end

  defp get_outputs(%Graph{output: outputs}) do
    Enum.map(outputs, fn %Value{name: name} -> name end)
  end

  defp get_nodes(pruned_nodes, inp, params, used_params) do
    # IO.puts "Calling get_nodes ..."
    # IO.inspect inp, structs: false
    {model, used_params} = Enum.reduce(pruned_nodes, {inp, used_params}, fn %Node{op_type: op_type} = op_node,
                                                     {axon, used_params} ->
      case op_type do
        "Abs" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.abs/1)

        "Acos" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.acos/1)

        "Acosh" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.acosh/1)

        "Add" ->
          to_axon_binary_op(op_node, axon, params, used_params, :add)

        "ArgMax" ->
          to_axon_reduction(op_node, axon, params, used_params, &Nx.argmax/2)

        "ArgMin" ->
          to_axon_reduction(op_node, axon, params, used_params, &Nx.argmin/2)

        "Asin" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.asin/1)

        "Asinh" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.asinh/1)

        "Atan" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.atan/1)

        "Atanh" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.atanh/1)

        "BatchNormalization" ->
          to_axon_batch_norm(op_node, axon, params, used_params)

        "Ceil" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.ceil/1)

        "Celu" ->
          # TODO(seanmor5): alpha attr
          to_axon_activation(op_node, axon, params, used_params, :celu)

        "Constant" ->
          to_axon_constant(op_node, axon, params, used_params)

        "Conv" ->
          to_axon_conv(op_node, axon, params, used_params)

        "Cos" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.cos/1)

        "Cosh" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.cosh/1)

        "Div" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} -> Nx.divide(x, y) end)

        "Elu" ->
          # TODO(seanmor5): alpha attr
          to_axon_activation(op_node, axon, params, used_params, :elu)

        "Equal" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} -> Nx.equal(x, y) end)

        "Erf" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.erf/1)

        "Exp" ->
          to_axon_activation(op_node, axon, params, used_params, :exp)

        "Flatten" ->
          to_axon_flatten(op_node, axon, params, used_params)

        "Concatenate" ->
          to_axon_concatenate(op_node, axon, params, used_params)

        "Floor" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.floor/1)

        "Gemm" ->
          to_axon_dense(op_node, axon, params, used_params)

        "GlobalAveragePool" ->
          to_axon_global_pool(op_node, axon, params, used_params)

        "GlobalLpPool" ->
          to_axon_global_pool(op_node, axon, params, used_params)

        "GlobalMaxPool" ->
          to_axon_global_pool(op_node, axon, params, used_params)

        "Greater" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} -> Nx.greater(x, y) end)

        "GreaterOrEqual" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} ->
            Nx.greater_equal(x, y)
          end)

        "HardSigmoid" ->
          # TODO(seanmor5): alpha, beta attrs
          to_axon_activation(op_node, axon, params, used_params, :hard_sigmoid)

        "Identity" ->
          to_axon_nx(op_node, axon, params, used_params, & &1)

        "Less" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} -> Nx.less(x, y) end)

        "LessOrEqual" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} ->
            Nx.less_equal(x, y)
          end)

        "Log" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.log/1)

        "MatMul" ->
          to_axon_dense(op_node, axon, params, used_params)

        "Mod" ->
          # TODO(seanmor5): Support fmod option
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} ->
            Nx.remainder(x, y)
          end)

        "Mul" ->
          to_axon_binary_op(op_node, axon, params, used_params, :multiply)

        "Neg" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.negate/1)

        "Not" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.logical_not/1)

        "Or" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} ->
            Nx.logical_or(x, y)
          end)

        "Pow" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} -> Nx.power(x, y) end)

        "ReduceMax" ->
          to_axon_reduction(op_node, axon, params, used_params, &Nx.reduce_max/2)

        "ReduceMin" ->
          to_axon_reduction(op_node, axon, params, used_params, &Nx.reduce_min/2)

        "ReduceProd" ->
          to_axon_reduction(op_node, axon, params, used_params, &Nx.product/2)

        "Relu" ->
          to_axon_activation(op_node, axon, params, used_params, :relu)

        "Reshape" ->
          to_axon_reshape(op_node, axon, params, used_params)

        "Round" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.round/1)

        "Selu" ->
          # TODO(seanmor5): alpha, gamma attrs
          to_axon_activation(op_node, axon, params, used_params, :selu)

        "Shape" ->
          to_axon_nx(op_node, axon, params, used_params, fn x ->
            x
            |> Nx.shape()
            |> Tuple.to_list()
            |> Nx.tensor(backend: Nx.Defn.Expr)
          end)

        "Sigmoid" ->
          to_axon_activation(op_node, axon, params, used_params, :sigmoid)

        "Sign" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.sign/1)

        "Sin" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.sin/1)

        "Sinh" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.sinh/1)

        "Size" ->
          to_axon_nx(op_node, axon, params, used_params, fn x ->
            x
            |> Nx.size()
            |> Nx.tensor(backend: Nx.Defn.Expr)
          end)

        "Softmax" ->
          # TODO(seanmor5): axis attr
          to_axon_activation(op_node, axon, params, used_params, :softmax)

        "Softplus" ->
          to_axon_activation(op_node, axon, params, used_params, :softplus)

        "Softsign" ->
          to_axon_activation(op_node, axon, params, used_params, :softsign)

        "Sqrt" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.sqrt/1)

        "Sub" ->
          to_axon_binary_op(op_node, axon, params, used_params, :subtract)

        "Tan" ->
          to_axon_nx(op_node, axon, params, used_params, &Nx.tan/1)

        "Tanh" ->
          to_axon_activation(op_node, axon, params, used_params, :tanh)

        "Transpose" ->
          to_axon_transpose(op_node, axon, params, used_params)

        "Unsqueeze" ->
          to_axon_unsqueeze(op_node, axon, params, used_params)

        "Xor" ->
          to_axon_binary_op(op_node, axon, params, used_params, fn {x, y} ->
            Nx.logical_xor(x, y)
          end)

        "MaxPool" ->
          to_axon_max_pool(op_node, axon, params, used_params)

        "Pad" ->
          to_axon_pad(op_node, axon, params, used_params)

        op ->
          raise "unsupported #{op} op in graph"
      end
    end)

    {model, params}
  end

  # Builds a generic Nx layer by applying the given operation
  # to the input. Most of these functions are generic element-wise
  # operations such as Abs, Acos, etc.
  #
  # TODO(seanmor5): Replace with Axon.layer when we have better shape
  # inference
  defp to_axon_nx(%Node{input: [input], output: [output_name]}, axon, params, used_params, fun) do
    axon_input = input_or_param!(input, params, axon, used_params)
    updated_axon = Map.put(axon, output_name, Axon.nx(axon_input, fun, name: output_name))
    {updated_axon, used_params}
  end

  # Builds a generic Nx layer by applying the given reduction operation
  # to the input.
  #
  # TODO(seanmor5): Replace with Axon.layer when we have better shape
  # inference
  defp to_axon_reduction(
         %Node{input: [input], attribute: attrs, output: [output_name]},
         axon,
         params,
         used_params,
         reduce_fun
       ) do
    reduce_options = options!(attrs)

    axes = reduce_options["axes"]
    keepdims = reduce_options["keepdims"]
    keep_axes = if keepdims == 1, do: true, else: false

    axon_input = input_or_param!(input, params, axon, used_params)

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.nx(axon_input, reduce_fun,
          name: output_name,
          opts: [axes: axes, keep_axes: keep_axes]
        )
      )

    {updated_axon, used_params}
  end

  # Builds an Axon dense layer from an ONNX MatMul or GEMM Node. MatMul
  # nodes do not account for bias (they're treated as a separate operation
  # in the graph). GEMM Nodes are a bit more in-depth.
  #
  # TODO(seanmor5): Handle alpha, beta attrs
  defp to_axon_dense(
         %Node{op_type: op_type, input: inputs, name: name, output: [output_name], attribute: attrs} = node,
         axon,
         params,
         used_params
       ) do
    [input, weight | maybe_bias] = inputs

    input = input_or_param!(input, params, axon, used_params)
    weight = input_or_param!(%{layer: name, value: weight}, params, axon, used_params)

    # IO.inspect %{node: node, axon: axon, params: params, used_params: used_params}

    # IO.puts "Got weight:"
    # IO.inspect weight

    # raise "Stop execution after obtaining weight"

    case op_type do
      "MatMul" ->
        {_, units} = Nx.shape(weight)

        updated_axon =
          Map.put(
            axon,
            output_name,
            Axon.dense(input, units, use_bias: false, name: output_name)
          )

        updated_params = Map.put(used_params, output_name <> "_kernel", weight)
        {updated_axon, updated_params}

      "Gemm" ->
        case name do
          "embedding" <> _ ->
            {vocab_size, embedding_size} = Nx.shape(weight)
            results = {
              Map.put(
                axon,
                output_name,
                Axon.embedding(input, vocab_size, embedding_size, name: output_name) # TODO: Add support for kernel_initializer option
              ),
              Map.put(used_params, output_name <> "_kernel", weight)
            }
            # raise "Cannot handle embedding layer with size #{embedding_size}"
          _ ->
            dense_options = options!(attrs)

            # TODO(seanmor5): Handle alpha, beta
            _alpha = dense_options["alpha"]
            _beta = dense_options["beta"]

            trans_a = dense_options["transA"]
            trans_b = dense_options["transB"]

            input =
              if trans_a == 1 do
                Nx.transpose(input)
              else
                input
              end

            weight =
              if trans_b == 1 do
                Nx.transpose(weight)
              else
                weight
              end

            {_, units} = Nx.shape(weight)

            updated_axon =
              Map.put(
                axon,
                output_name,
                Axon.dense(input, units, use_bias: maybe_bias != [], name: output_name)
              )

            updated_params =
              if maybe_bias == [] do
                Map.put(used_params, output_name <> "_kernel", weight)
              else
                [bias] = maybe_bias
                bias = input_or_param!(bias, params, axon, used_params)

                used_params
                |> Map.put(output_name <> "_kernel", weight)
                |> Map.put(output_name <> "_bias", bias)
              end

              # IO.puts "Updated axon after processing dense layer >>>"
              # IO.inspect updated_axon, structs: false 

              {updated_axon, updated_params}
        end
    end
  end

  # Builds an Axon layer from an element-wise binary operation. Binary
  # op is either an atom representing one of Axon's legitimate Binary op
  # layers, or a function to be used in a custom layer.
  #
  # TODO(seanmor5): Verify broadcasting semantics
  defp to_axon_binary_op(
         %Node{input: [x, y], output: [output_name]},
         axon,
         params,
         used_params,
         binary_op
       ) do
    inp1 = input_or_param!(x, params, axon, used_params)
    inp2 = input_or_param!(y, params, axon, used_params)

    updated_axon =
      case binary_op do
        op when is_atom(op) ->
          Map.put(axon, output_name, apply(Axon, op, [inp1, inp2, [name: output_name]]))

        fun when is_function(fun, 2) ->
          # TODO(seanmor5): Use Axon.layer when shape inference improves
          Map.put(axon, output_name, Axon.nx({inp1, inp2}, fun, name: output_name))
      end

    {updated_axon, used_params}
  end

  defp to_axon_max_pool(
         %Node{op_type: "MaxPool", input: [inp], attribute: attrs, output: [output_name]},
         axon,
         params,
         used_params
       ) do
    max_pool_options = options!(attrs)

    kernel_shape = max_pool_options["kernel_shape"]
    strides = max_pool_options["strides"]
    pads = max_pool_options["pads"]
    auto_pad = max_pool_options["auto_pad"]

    kernel_size = List.to_tuple(kernel_shape)
    padding_config = padding!(auto_pad, pads)

    inp = input_or_param!(inp, params, axon, used_params)

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.max_pool(inp,
          kernel_size: kernel_size,
          strides: strides,
          padding: padding_config,
          name: output_name
        )
      )

    {updated_axon, used_params}
  end

  defp to_axon_conv(%Node{op_type: "Conv"} = conv_node, axon, params, used_params) do
    %{attribute: attrs, input: input, output: [output_name]} = conv_node

    conv_options = options!(attrs)

    auto_pad = conv_options["auto_pad"]
    # dilations = conv_options["dilations"]
    group = conv_options["group"]
    kernel_shape = conv_options["kernel_shape"]
    pads = conv_options["pads"]
    strides = conv_options["strides"]

    padding_config = padding!(auto_pad, pads)
    kernel_size = List.to_tuple(kernel_shape)

    [inp, kernel | maybe_bias] = input

    axon_inp = input_or_param!(inp, params, axon, used_params)

    # Parameters can either be embedded in the graph as constants or
    # passed as parameters
    {axon_kernel, units} =
      cond do
        Map.has_key?(params, kernel) ->
          kernel = params[kernel]
          {kernel, elem(Nx.shape(kernel), 0)}

        Map.has_key?(axon, kernel) ->
          %{opts: [value: kernel]} = axon[kernel]
          {kernel, elem(Nx.shape(kernel), 0)}

        true ->
          raise "unable to find kernel for conv"
      end

    updated_params = Map.put(used_params, output_name <> "_kernel", axon_kernel)

    updated_params =
      if maybe_bias == [] do
        updated_params
      else
        [bias] = maybe_bias
        axon_bias = params[bias]
        Map.put(updated_params, output_name <> "_bias", axon_bias)
      end

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.conv(axon_inp, units,
          kernel_size: kernel_size,
          feature_group_size: group,
          padding: padding_config,
          strides: strides,
          use_bias: maybe_bias != [],
          name: output_name
        )
      )

    {updated_axon, updated_params}
  end

  defp to_axon_pad(
         %Node{op_type: "Pad", input: inputs, output: [output_name], attribute: attrs},
         axon,
         params,
         used_params
       ) do
    pad_options = options!(attrs)

    case pad_options["mode"] do
      "constant" ->
        :ok

      nil ->
        :ok

      mode ->
        raise "unsupported padding mode #{inspect(mode)}"
    end

    [data, pads | maybe_constant] = inputs

    inp = input_or_param!(data, params, axon, used_params)
    # TODO(seanmor5): Pads should probably be scrubbed from the graph
    # and parameters
    pads = input_or_param!(pads, params, axon, used_params)

    padding_config =
      pads.ints
      |> Enum.chunk_every(2)
      |> Enum.zip()

    constant_value =
      case maybe_constant do
        [] ->
          0

        [value] ->
          tensor!(value)
      end

    updated_axon =
      Map.put(axon, output_name, Axon.pad(inp, padding_config, constant_value, name: output_name))

    {updated_axon, used_params}
  end

  # TODO(seanmor5): Mean and variance
  defp to_axon_batch_norm(
         %Node{
           op_type: "BatchNormalization",
           input: [inp, gamma, beta, _mean, _var],
           output: [output_name]
         },
         axon,
         params,
         used_params
       ) do
    inp = input_or_param!(inp, params, axon, used_params)

    gamma = input_or_param!(gamma, params, axon, used_params)
    beta = input_or_param!(beta, params, axon, used_params)

    updated_axon = Map.put(axon, output_name, Axon.batch_norm(inp, name: output_name))

    updated_params =
      used_params
      |> Map.put(output_name <> "_gamma", gamma)
      |> Map.put(output_name <> "_beta", beta)

    {updated_axon, updated_params}
  end

  # Builds an axon activation layer with the given activation function.
  # `activation` must be a legitimate Axon activation. `activation` functions
  # are all element-wise with 1 input. Optionally has activation options.
  #
  # TODO(seanmor5): Handle activation options
  defp to_axon_activation(
         %Node{input: [inp], output: [output_name]},
         axon,
         params,
         used_params,
         activation
       ) do
    inp = input_or_param!(inp, params, axon, used_params)
    {Map.put(axon, output_name, Axon.activation(inp, activation, name: output_name)), used_params}
  end

  defp to_axon_global_pool(
         %Node{op_type: op_type, attribute: attrs, input: [inp], output: [output_name]},
         axon,
         params,
         used_params
       ) do
    inp = input_or_param!(inp, params, axon, used_params)

    updated_axon =
      case op_type do
        "GlobalAveragePool" ->
          Map.put(axon, output_name, Axon.global_avg_pool(inp, name: output_name))

        "GlobalMaxPool" ->
          Map.put(axon, output_name, Axon.global_max_pool(inp, name: output_name))

        "GlobalLpPool" ->
          lp_pool_options = options!(attrs)

          Map.put(
            axon,
            output_name,
            Axon.global_lp_pool(inp, norm: lp_pool_options["p"], name: output_name)
          )
      end

    {updated_axon, used_params}
  end

  # Builds an Axon layer which returns a constant with the given
  # value. Constants are embedded in custom layers which just yield
  # the value of the constant here. They are not treated as parameters
  defp to_axon_constant(
         %Node{op_type: "Constant", attribute: attrs, output: [output_name]},
         axon,
         _,
         used_params
       ) do
    constant_options = options!(attrs)

    const =
      cond do
        constant_options["sparse_value"] ->
          raise ArgumentError, "sparse tensors are not supported"

        constant_options["value"] ->
          Axon.constant(tensor!(constant_options["value"]), namme: output_name)

        constant_options["value_float"] ->
          Axon.constant(Nx.tensor(constant_options["value_float"], type: {:f, 32}),
            name: output_name
          )

        constant_options["value_floats"] ->
          Axon.constant(Nx.tensor(constant_options["value_floats"], type: {:f, 32}),
            name: output_name
          )

        constant_options["value_int"] ->
          Axon.constant(Nx.tensor(constant_options["value_int"], type: {:s, 64}),
            name: output_name
          )

        constant_options["value_ints"] ->
          Axon.constant(Nx.tensor(constant_options["value_ints"], type: {:s, 64}),
            name: output_name
          )

        constant_options["value_string"] or constant_options["value_strings"] ->
          raise ArgumentError, "string tensors are not supported"

        true ->
          raise ArgumentError, "invalid constant tensor type"
      end

    updated_axon = Map.put(axon, output_name, const)

    {updated_axon, used_params}
  end

  defp to_axon_reshape(
         %Node{op_type: "Reshape", input: [inp], attribute: attrs, output: [output_name]} = node,
         axon,
         params,
         used_params
  ) do

    # IO.inspect %{node: node, axon: axon, params: params, used_params: used_params}, structs: false

    reshape_options = options!(attrs)

    # IO.inspect reshape_options, structs: false

    inp = input_or_param!(inp, params, axon, used_params)

    new_shape =
      reshape_options["shape"]
      |> decode_shape

    # IO.inspect new_shape

    # raise "Stop execution before reshape layer decoding"

    {
      Map.put(
        axon,
        output_name,
        Axon.reshape(
          inp,
          List.to_tuple(
            case Tuple.to_list(new_shape) do
              [nil | non_batch_size_dimensions] -> non_batch_size_dimensions
              dimensions -> dimensions
            end
          ),
          name: output_name
        )
      ), used_params
    }
  end

  defp to_axon_flatten(
         %Node{op_type: "Flatten", input: [inp], output: [output_name]},
         axon,
         params,
         used_params
       ) do
    inp = input_or_param!(inp, params, axon, used_params)

    {Map.put(axon, output_name, Axon.flatten(inp, name: output_name)), used_params}
  end

  defp to_axon_concatenate(
    %Node{
      op_type: "Concatenate",
      input: inputs,
      output: [output_name],
      attribute: [
        %Onnx.AttributeProto{
          type: :INT,
          name: "axis",
          i: axis
        } | _ ]
    } = node,
    axon,
    params,
    used_params
  ) do
    # %{node: node, axon: axon, params: params, used_params: used_params} |> IO.inspect structs: false
    # inp = input_or_param!(inp, params, axon, used_params)

    {
      Map.put(
        axon,
        output_name,
        Axon.concatenate(for input_layer_name <- inputs do input_or_param!(input_layer_name, params, axon, used_params) end,
        name: output_name,
        axis: axis
      )
      ), used_params
    } # |> IO.inspect structs: false

    # raise "Incomplete implementation of the concatenation layer deserializer"
  end

  # Builds an Axon transpose layer. Transpose is given by
  # the perm option in Node attribute.
  defp to_axon_transpose(
         %Node{op_type: "Transpose", input: [input], attribute: attrs, output: [output_name]},
         axon,
         params,
         used_params
       ) do
    inp = input_or_param!(input, params, axon, used_params)

    transpose_options = options!(attrs)

    permutation = transpose_options["perm"]

    updated_axon = Map.put(axon, output_name, Axon.transpose(inp, permutation, name: output_name))

    {updated_axon, used_params}
  end

  # Builds an unsqueeze layer using a custom Nx layer with the given
  # input and axes.
  #
  # TODO(seanmor5): Use Axon.layer
  defp to_axon_unsqueeze(
         %Node{op_type: "Unsqueeze", input: [input], attribute: attrs, output: [output_name]},
         axon,
         params,
         used_params
       ) do
    unsqueeze_options = options!(attrs)

    inp = input_or_param!(input, params, axon, used_params)

    axes = unsqueeze_options["axes"]

    fun = fn input ->
      Enum.reduce(axes, input, fn axis, x -> Nx.new_axis(x, axis) end)
    end

    case inp do
      %Nx.Tensor{} = tensor ->
        updated_params = Map.put(used_params, output_name, fun.(tensor))
        {axon, updated_params}

      %Axon{} = model ->
        updated_axon = Map.put(axon, output_name, Axon.nx(model, fun, name: output_name))
        {updated_axon, used_params}
    end
  end

  # TODO(seanmor5): Handle segments
  def tensor!(%Tensor{data_type: dtype, dims: dims} = tensor) do
    shape = List.to_tuple(dims)

    case dtype do
      1 ->
        to_nx_tensor(tensor.float_data, tensor.raw_data, {:f, 32}, shape)

      2 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:u, 8}, shape)

      3 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:s, 8}, shape)

      4 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:u, 16}, shape)

      5 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:s, 16}, shape)

      6 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:s, 32}, shape)

      7 ->
        to_nx_tensor(tensor.int64_data, tensor.raw_data, {:s, 64}, shape)

      8 ->
        raise "unsupported Nx tensor type: string"

      9 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:u, 8}, shape)

      10 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:f, 16}, shape)

      11 ->
        to_nx_tensor(tensor.double_data, tensor.raw_data, {:f, 64}, shape)

      12 ->
        to_nx_tensor(tensor.uint64_data, tensor.raw_data, {:u, 32}, shape)

      13 ->
        to_nx_tensor(tensor.uint64_data, tensor.raw_data, {:u, 64}, shape)

      14 ->
        # TODO(seanmor5): When complex is supported, tensor.float_data
        raise "unsupported Nx tensor type: C64"

      15 ->
        # TODO(seanmor5): When complex is supported, tensor.double_data
        raise "unsupported Nx tensor type: C128"

      16 ->
        to_nx_tensor([], tensor.raw_data, {:bf, 16}, shape)
    end
  end

  defp to_nx_tensor([], <<>>, _, _) do
    raise "unsupported empty Nx tensor"
  end

  defp to_nx_tensor([], raw, type, shape) do
    raw
    |> Nx.from_binary(type)
    |> Nx.reshape(shape)
  end

  defp to_nx_tensor(data, _, type, shape) do
    data
    |> Nx.tensor(type: type)
    |> Nx.reshape(shape)
  end

  defp input_or_param!(%{layer: layer, value: name}, params, axon, used_params) do
    cond do
      Map.has_key?(params, layer) ->
        case params[layer][name] do
          nil -> raise "Unable to find parameter #{name} for layer #{layer}"
          value -> value
        end

      true ->
        raise "unable to find value with name #{inspect(name)} in" <>
                " parameters or model"
    end
  end

  defp input_or_param!(name, params, axon, used_params) do
    cond do
      Map.has_key?(axon, name) ->
        axon[name]

      Map.has_key?(used_params, name) ->
        used_params[name]

      true ->
        raise "unable to find value with name #{inspect(name)} in" <>
                " parameters or model"
    end
  end

  defp padding!(auto_pad, pads) do
    case auto_pad do
      val when val == "NOTSET" or val == nil ->
        pads
        |> Enum.chunk_every(2)
        |> Enum.zip()

      val when val == "SAME_UPPER" or val == "SAME_LOWER" ->
        :same

      "VALID" ->
        :valid
    end
  end

  defp options!(attrs) when is_list(attrs) do
    Enum.reduce(attrs, %{}, fn %Attribute{type: type, name: name} = attr, options ->
      case type do
        :FLOAT ->
          Map.put(options, name, attr.f)

        :INT ->
          Map.put(options, name, attr.i)

        :STRING ->
          Map.put(options, name, attr.s)

        :TENSOR ->
          Map.put(options, name, attr.t)

        :GRAPH ->
          Map.put(options, name, attr.g)

        :SPARSE_TENSOR ->
          Map.put(options, name, attr.sparse_tensor)

        :TYPE_PROTO ->
          Map.put(options, name, attr.tp)

        :FLOATS ->
          Map.put(options, name, attr.floats)

        :INTS ->
          Map.put(options, name, attr.ints)

        :STRINGS ->
          Map.put(options, name, attr.strings)

        :TENSORS ->
          Map.put(options, name, attr.tensors)

        :GRAPHS ->
          Map.put(options, name, attr.graphs)

        :SPARSE_TENSORS ->
          Map.put(options, name, attr.sparse_tensors)

        :TYPE_PROTOS ->
          Map.put(options, name, attr.type_protos)
      end
    end)
  end

  defp shape!(%Placeholder{shape: %Shape{dim: dims}}, dim_params) do
    dims
    |> Enum.map(fn %Dimension{value: value} ->
      case value do
        {:dim_value, val} ->
          val

        {:dim_param, key} ->
          unless Map.has_key?(dim_params, key) do
            raise "dimension #{inspect(key)} not found in provided dimensions," <>
                    " you must specify unknown dimension shapes at import time"
          end

          dim_params[key]

        _ ->
          raise ArgumentError, "unsupported dimension type"
      end
    end)
    # |> List.to_tuple()
  end
end
