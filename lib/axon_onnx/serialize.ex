defmodule AxonOnnx.Serialize do
  alias Onnx.ModelProto, as: Model
  alias Onnx.GraphProto, as: Graph
  alias Onnx.NodeProto, as: Node
  alias Onnx.ValueInfoProto, as: Value
  alias Onnx.AttributeProto, as: Attribute
  alias Onnx.OperatorSetIdProto, as: Opset
  alias Onnx.TypeProto, as: Type
  alias Onnx.TypeProto.Tensor, as: Placeholder
  alias Onnx.TensorShapeProto, as: Shape
  alias Onnx.TensorShapeProto.Dimension, as: Dimension

  @onnx_ir_version 3
  @onnx_opset_version 13
  @producer_name "AxonOnnx"
  @producer_version "0.1.0-dev"

  # TODO(seanmor5): Multi-output models
  def __export__(%Axon{name: output_name} = axon, params, opts \\ []) do
    fname = opts[:filename] || output_name <> ".onnx"

    onnx_model = to_onnx_model(axon, params, opts)
    # IO.puts "before encoding model"
    # IO.inspect Model
    encoded = Model.encode!(onnx_model)
    # IO.puts "after encoding model"

    {:ok, file} = File.open(fname, [:write])
    IO.binwrite(file, encoded)
    File.close(file)
  end

  def to_onnx_model(axon, params, opts) do
    model_version = opts[:version] || 1
    doc_string = opts[:doc_string] || "An Axon Model"

    opset = %Opset{domain: "", version: @onnx_opset_version}

    graph = to_onnx_graph(axon, params)

    %Model{
      ir_version: @onnx_ir_version,
      producer_name: @producer_name,
      producer_version: @producer_version,
      domain: "",
      model_version: model_version,
      doc_string: doc_string,
      graph: graph,
      opset_import: [opset]
    }
  end
  def handle_param_names(nodes, param_names, params_or_initializers, handle_param) do
    nodes
    |> Stream.filter(fn x ->
      x.op_type != "Concatenate"
    end)
    |> Stream.with_index
    |> Enum.each(fn ({node, i}) ->
      # IO.puts "ALL INITS"
      # IO.inspect params_or_initializers
      # IO.inspect nodes
      handle_param.({node.name, Enum.at(param_names, i)}, params_or_initializers[node.name][Enum.at(param_names, i)])
      # to_initializers(params_or_initializers[node.name], [Enum.at(param_names, i)])# Enum.at(param_names, i))
    end)
  end

  def to_onnx_graph(%Axon{name: output_name} = axon, params_or_initializers) do
    {inputs, param_names, nodes} = to_onnx(axon, [], [], [])
    # Building the initializers with Tensors will result in a bunch of expensive
    # copies, so we instead accumulate names and then use them to build initializers
    # later
    # initializers = nodes
    #                |> Stream.filter(fn x ->
    #                  x.op_type != "Concatenate"
    #                end)
    #                |> Stream.with_index
    #                |> Enum.map(fn ({node, i}) ->
    #                  IO.puts "ALL INITS"
    #                  IO.inspect params_or_initializers
    #                  IO.inspect nodes
    #                  to_initializers(params_or_initializers[node.name], [Enum.at(param_names, i)])# Enum.at(param_names, i))
    #                end)
    #
    # IO.inspect %{inputs: inputs, param_names: param_names, nodes: nodes}

    initializers = to_initializers(params_or_initializers, param_names) # |> IO.inspect

    # Parameters need to be specified as graph inputs as well
    # updated_inputs = inputs ++ handle_param_names(nodes, param_names, params_or_initializers, fn (name, x) -> to_value_info(name, Nx.shape(x)) end)
    updated_inputs =
      param_names
      |> Enum.reduce(
        inputs,
        fn x, acc ->
          case x do
            %{layer: layer, value: name, differentiable: false, state: state} ->
              acc
              # to_value_info(name, Nx.shape(state))
            %{layer: layer, value: name} ->
              [ to_value_info(name, Nx.shape(params_or_initializers[layer][name])) | acc ]
          end
          # [param_value | acc]
        end
      )

    # {_, _} = 2

    # IO.puts "GRAPH ======"

    %Graph{
      node: Enum.reverse(nodes),
      name: output_name,
      input: updated_inputs,
      output: [to_value_info(axon)],
      initializer: initializers
    } # |> IO.inspect
  end

  def to_onnx(%Axon{op: :input} = axon, inputs, param_names, nodes) do
    input_value = to_value_info(axon)
    {[input_value | inputs], param_names, nodes}
  end

  ## Linear

  def to_onnx(
         %Axon{
           op: :dense,
           name: name,
           parent: %Axon{name: inp_name} = parent,
           params: params,
           opts: [use_bias: use_bias]
         },
         inputs,
         param_names,
         nodes
       ) do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    %{name: k_name} = params["kernel"]
    k_param = %{layer: name, value: k_name}

    {node_inputs, updated_param_names} =
      if use_bias do
        %{name: b_name} = params["bias"]
        b_param = %{layer: name, value: b_name}

        {[inp_name, k_name, b_name], [k_param, b_param | param_names]}
      else
        {[inp_name, k_name], [k_param | param_names]}
      end

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      op_type: "Gemm"
    }

    {inputs, updated_param_names, [node | nodes]}
  end

  def to_onnx(
         %Axon{
           op: :embedding,
           name: name,
           parent: %Axon{name: inp_name} = parent,
           params: params,
         },
         inputs,
         param_names,
         nodes
       ) do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    inp_param = inp_name # %{layer: inp_name}

    %{name: k_name} = params["kernel"]
    k_param = %{layer: name, value: k_name}

    {node_inputs, updated_param_names} = {[inp_param, k_name], [k_param | param_names]}

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      op_type: "Gemm"
    }

    {inputs, updated_param_names, [node | nodes]}
  end

  def to_onnx(
         %Axon{
           op: :flatten,
           name: name,
           parent: %Axon{name: inp_name} = parent
           # params: params,
         },
         inputs,
         param_names,
         nodes
       ) do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    inp_param = inp_name # %{layer: inp_name}

    {node_inputs, updated_param_names} = {[inp_param], param_names}

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      op_type: "Flatten"
    }

    {inputs, updated_param_names, [node | nodes]}
  end

  def to_onnx(
         %Axon{
           op: :pad,
           name: name,
           parent: %Axon{name: inp_name} = parent,
           opts: [padding_config: padding_config, value: constant_value]
           # params: params,
         } = axon,
         inputs,
         param_names,
         nodes
  ) do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes) # |> IO.inspect

    # IO.inspect %{axon: axon, inputs: inputs, param_names: param_names, nodes: nodes}, structs: false
    
    # IO.puts "Serializing pad layer..."
    # IO.inspect axon, structs: false

    mode_attr = to_attr(
      "mode",
      :STRING,
      "constant" # TODO: support other modes (reflect and edge)
    ) # |> IO.inspect

    # constant_value_attr = to_attr(
    #   "constant_value",
    #   :FLOAT,
    #   constant_value
    # )

    pads_value = padding_config
                 |> Enum.reduce([], fn {n_left_pads, n_right_pads}, n_pads -> [ n_right_pads | [ n_left_pads | n_pads] ] end)
                 |> Enum.reverse
                 |> Nx.tensor
           # |> Enum.join(" ")
           # |> IO.inspect
    pads_param = %{
      layer: name,
      value: "config",
      differentiable: false,
      state: pads_value
    }

    inp_param = inp_name # %{layer: inp_name}

    {node_inputs, updated_param_names} = {["config", inp_param], [pads_param | param_names]}

    # node_inputs = 
    #   case {mode_attr.s, [ pads | node_inputs ]} do
    #     {"constant", inputs} -> [ "#{constant_value}" | inputs ]
    #     {_, inputs} -> inputs
    #   end
    #   |> Enum.reverse
    #   # |> IO.inspect
    
    {node_inputs, updated_param_names} = case mode_attr.s do
      "constant"  -> 
        constant_value_param = %{
          layer: name,
          value: "constant_value",
          differentiable: false,
          state: Nx.tensor(constant_value)
        }
        {["constant_value" | node_inputs], [constant_value_param | updated_param_names]}
      _ -> {node_inputs, updated_param_names}
    end

    node = %Node{
      input: Enum.reverse(node_inputs),
      output: [name],
      name: name,
      op_type: "Pad",
      attribute: [mode_attr]
    }

    # IO.inspect node
    # IO.inspect updated_param_names

    # {_, _} = 2

    {inputs, updated_param_names, [node | nodes]}
  end

  def to_onnx(
    %Axon{
      op: :reshape,
      name: name,
      output_shape: shape,
      parent: %Axon{name: inp_name} = parent
      # params: params,
    }, # = axon,
    inputs,
    param_names,
    nodes
  ) do
    # IO.inspect axon, structs: false

    output_shape_attr = to_attr(
      "shape",
      :INTS,
      case Tuple.to_list(shape) do
        [nil | non_batch_size_dimensions] -> [-1 | non_batch_size_dimensions]
        dimensions -> dimensions
      end
    )

    # raise "Stop before reshape layer serialization"
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    inp_param = inp_name # %{layer: inp_name}

    {node_inputs, updated_param_names} = {[inp_param], param_names}

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      op_type: "Reshape",
      attribute: [output_shape_attr]
    }

    {inputs, updated_param_names, [node | nodes]}
  end

  def to_onnx(
         %Axon{
           op: :concatenate,
           name: name,
           parent: parents,
           params: _, # params,
           opts: [axis: axis]
         },
         _, # inputs,
         _, # param_names,
         _ # nodes
       ) do

         # {inp_names, inputs, param_names, nodes} = 
         # IO.inspect(inputs)
         # inp_names = 2
         # Enum.zip([parents, inputs, param_names, nodes])
         # |> List.to_tuple
         # |> IO.inspect
         [inputs, param_names, nodes, inp_names] = [
           parents,
           for _ <- 1..length(parents) do [] end,
           for _ <- 1..length(parents) do [] end,
           for _ <- 1..length(parents) do [] end
         ]
         |> Stream.zip
         |> Stream.map( # inputs, param_names, nodes
           fn {%Axon{name: inp_name} = parent, inputs, param_names, nodes} ->
             Tuple.append(to_onnx(parent, inputs, param_names, nodes), inp_name)
             |> Tuple.to_list
           end
         )
         |> Stream.zip 
         |> Enum.map(fn x ->
           x
           |> Tuple.to_list
           |> List.flatten
         end)
         # |> IO.inspect
    # {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)
    # {_, _} = 2

    axis_attr = to_attr("axis", :INT, axis)

    {node_inputs, updated_param_names} = {for inp_name <- inp_names do inp_name end, param_names} # %{layer: inp_name}

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      attribute: [axis_attr],
      op_type: "Concatenate"
    }

    {inputs, updated_param_names, [node | nodes]}
  end

  ## Convolution

  def to_onnx(
         %Axon{
           op: :conv,
           name: name,
           parent: %Axon{name: inp_name} = parent,
           params: params,
           opts: opts
         },
         inputs,
         param_names,
         nodes
       ) do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    use_bias = opts[:use_bias]
    strides = opts[:strides]
    padding = opts[:padding]

    strides_attr = to_attr("strides", :INTS, strides)

    padding_attr =
      case padding do
        :valid ->
          to_attr("auto_pad", :STRING, "VALID")

        :same ->
          to_attr("auto_pad", :STRING, "SAME_UPPER")

        padding when is_list(padding) ->
          {pad_begins, pad_ends} = Enum.unzip(padding)
          to_attr("pads", :INTS, pad_begins ++ pad_ends)
      end

    # TODO: Dilations

    %{name: k_name} = params["kernel"]

    {node_inputs, updated_param_names} =
      if use_bias do
        %{name: b_name} = params["bias"]
        {[inp_name, k_name, b_name], [k_name, b_name | param_names]}
      else
        {[inp_name, k_name], [k_name | param_names]}
      end

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      attribute: [strides_attr, padding_attr],
      op_type: "Conv"
    }

    {inputs, updated_param_names, [node | nodes]}
  end

  ## Pooling

  @supported_pooling [:max_pool, :avg_pool, :lp_pool]

  def to_onnx(
         %Axon{op: pool, name: name, parent: %Axon{name: inp_name} = parent, opts: opts},
         inputs,
         param_names,
         nodes
       )
       when pool in @supported_pooling do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    kernel_size = opts[:kernel_size]
    strides = opts[:strides]
    padding = opts[:padding]

    strides_attr = to_attr("strides", :INTS, strides)
    kernel_shape_attr = to_attr("kernel_shape", :INTS, Tuple.to_list(kernel_size))

    padding_attr =
      case padding do
        :valid ->
          to_attr("auto_pad", :STRING, "VALID")

        :same ->
          to_attr("auto_pad", :STRING, "SAME_UPPER")

        padding when is_list(padding) ->
          {pad_begins, pad_ends} = Enum.unzip(padding)
          to_attr("pads", :INTS, pad_begins ++ pad_ends)
      end

    # TODO: Dilations

    {op_type, extra_attrs} =
      case pool do
        :lp_pool ->
          p_attr = to_attr("p", :INT, opts[:norm])
          {"LpPool", [p_attr]}

        :max_pool ->
          {"MaxPool", []}

        :avg_pool ->
          count_include_pad_attr = to_attr("count_include_pad", :INT, 1)
          {"AveragePool", [count_include_pad_attr]}
      end

    node_inputs = [inp_name]

    node = %Node{
      input: node_inputs,
      output: [name],
      name: name,
      attribute: [padding_attr, strides_attr, kernel_shape_attr | extra_attrs],
      op_type: op_type
    }

    {inputs, param_names, [node | nodes]}
  end

  ## Global Pooling

  @supported_global_pooling [:global_avg_pool, :global_lp_pool, :global_max_pool]

  def to_onnx(
         %Axon{
           op: pool,
           name: name,
           parent: %Axon{name: inp_name, output_shape: shape} = parent,
           opts: opts
         },
         inputs,
         param_names,
         nodes
       )
       when pool in @supported_global_pooling do
    {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

    keep_axes = opts[:keep_axes]

    {op_type, attrs} =
      case pool do
        :global_avg_pool ->
          {"GlobalAveragePool", []}

        :global_lp_pool ->
          {"GlobalLpPool", [to_attr("p", :INT, opts[:norm])]}

        :global_max_pool ->
          {"GlobalMaxPool", []}
      end

    node_inputs = [inp_name]

    nodes =
      if keep_axes do
        node = %Node{
          input: node_inputs,
          output: [name],
          name: name,
          attribute: attrs,
          op_type: op_type
        }

        [node | nodes]
      else
        pre_squeeze_name = name <> "_pre_squeeze"

        pre_squeeze_node = %Node{
          input: node_inputs,
          output: [pre_squeeze_name],
          name: pre_squeeze_name,
          attribute: attrs,
          op_type: op_type
        }

        constant_name = name <> "_squeeze_axes"
        axes = Enum.to_list(2..(Nx.rank(shape) - 1)//1)
        axes_tensor = nx_to_tensor_proto(%{value: constant_name, layer: name}, Nx.tensor(axes))
        value_attr = to_attr("value", :TENSOR, axes_tensor)

        constant_node = %Node{
          output: [constant_name],
          name: constant_name,
          attribute: [value_attr],
          op_type: "Constant"
        }

        node = %Node{
          input: [pre_squeeze_name, constant_name],
          output: [name],
          name: name,
          op_type: "Squeeze"
        }

        [node, constant_node, pre_squeeze_node | nodes]
      end

    {inputs, param_names, nodes}
  end

  ## Activations

  @supported_activations [
    {:celu, "Celu"},
    {:elu, "Elu"},
    {:exp, "Exp"},
    {:hard_sigmoid, "HardSigmoid"},
    {:leaky_relu, "LeakyRelu"},
    {:linear, "Identity"},
    {:relu, "Relu"},
    {:sigmoid, "Sigmoid"},
    {:selu, "Selu"},
    {:softmax, "Softmax"},
    {:softplus, "Softplus"},
    {:softsign, "Softsign"},
    {:tanh, "Tanh"}
  ]

  for {op, onnx_op} <- @supported_activations do
    def to_onnx(
           %Axon{op: unquote(op), name: name, parent: %Axon{name: input_name} = parent},
           inputs,
           param_names,
           nodes
         ) do
      {inputs, param_names, nodes} = to_onnx(parent, inputs, param_names, nodes)

      node_inputs = [input_name]

      node = %Node{
        input: node_inputs,
        output: [name],
        name: name,
        op_type: unquote(onnx_op)
      }

      {inputs, param_names, [node | nodes]}
    end
  end

  def to_attr(name, type, value) do
    case type do
      :INT ->
        %Attribute{name: name, type: :INT, i: value}

      :INTS ->
        %Attribute{name: name, type: :INTS, ints: value}

      :STRING ->
        %Attribute{name: name, type: :STRING, s: value}

      :TENSOR ->
        %Attribute{name: name, type: :TENSOR, t: value}
    end
  end

  def to_initializers(params_or_initializers, param_names) do
    # IO.puts "Params or initializers >>>"
    # IO.inspect params_or_initializers
    # IO.puts "Param names >>>"
    # IO.inspect param_names
    param_names
    |> Enum.map(fn param ->
      # IO.puts "Param >>>"
      # IO.inspect param
      # IO.puts "Value >>>"
      # IO.inspect params_or_initializers[param.layer][param.value]
      # nx_to_tensor_proto(param, params_or_initializers[param])
      case param do
        %{layer: layer, value: name, differentiable: false, state: state} -> 
          nx_to_tensor_proto(param, state)
        %{layer: layer, value: name} ->
          nx_to_tensor_proto(param, params_or_initializers[layer][name]) # |> IO.inspect charlists: :as_lists
        _ -> raise "Invalid parameter description: #{IO.inspect param}"
      end
    end)
  end

  def to_value_info(%Axon{name: name, output_shape: shape}) do
    input_type = %Type{value: {:tensor_type, to_placeholder(shape)}}
    %Value{name: name, type: input_type}
  end

  def to_value_info(param_name, shape) do
    input_type = %Type{value: {:tensor_type, to_placeholder(shape)}}
    %Value{name: param_name, type: input_type}
  end

  def to_placeholder(shape) do
    %Placeholder{shape: to_tensor_shape_proto(shape), elem_type: 1}
  end

  def to_tensor_shape_proto(shape, nil_replacement \\ -1) do
    dims =
      shape
      |> Tuple.to_list()
      |> Enum.map(&%Dimension{value: {:dim_value, &1}})
    
    dims = 
      dims
      |> Enum.map(fn x ->
        case x do
          %Onnx.TensorShapeProto.Dimension{value: {:dim_value, nil}} -> %Onnx.TensorShapeProto.Dimension{x | value: {:dim_value, nil_replacement}}
          _ -> x
        end
      end)

    %Shape{dim: dims}
  end

  def nx_to_tensor_proto(%{value: param_name, layer: param_layer}, tensor) do
    # IO.puts "Tensor shape >>>"
    dims = Nx.shape(tensor) |> Tuple.to_list() # |> IO.inspect
    # TODO: fix
    data_type =
      case Nx.type(tensor) do
        {:f, 32} ->
          1

        {:s, 64} ->
          7
      end

    raw_data = Nx.to_binary(tensor)
    %Onnx.TensorProto{
      name: param_name, # "#{param_name}_#{param_layer}",
      name_suffix: param_name, name_prefix: param_layer, dims: dims, data_type: data_type, raw_data: raw_data
    }
  end
end
