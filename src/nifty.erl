-module(nifty).
-export([
	 dereference/1,
	 free/1,
	 %% nif functions
	 raw_deref/1,
	 raw_free/1, 
	 float_deref/1,
	 double_deref/1,
	 list_to_cstr/1,
	 cstr_to_list/1,
	 pointer/0,
	 pointer/1,
	 raw_pointer_of/1,
	 mem_write/1,
	 mem_write/2,
	 mem_writer/2,
	 mem_read/2,
	 mem_alloc/1,
	 get_config/0,
	 get_env/0,
	 as_type/3,
	 get_types/0
	]).

-on_load(init/0).

init() -> %% loading code from jiffy
    PrivDir = case code:priv_dir(?MODULE) of
		  {error, _} ->
		      EbinDir = filename:dirname(code:which(?MODULE)),
		      AppPath = filename:dirname(EbinDir),
		      filename:join(AppPath, "priv");
		  Path ->
		      Path
	      end,
    erlang:load_nif(filename:join(PrivDir, "nifty"), 0).

get_types() ->
    %% builtin types:
    %%  int types ( [(short|long)] [(long|short)] int; [(signed|unsigned)] char )
    %%  float types ( float; double)
    %%  string (char *)
    %%  pointer (void *)
    dict:from_list(
      [{"signed char",{base,["char","signed","none"]}},
       {"char",{base,["char","signed","none"]}},
       {"unsigned char",{base,["char","unsigned","none"]}},
       {"short",{base,["int","signed","short"]}},
       {"unsigned short",{base,["int","unsigned","short"]}},
       {"int",{base,["int","signed","none"]}},
       {"unsigned int",{base,["int","unsigned","none"]}},
       {"long",{base,["int","signed","long"]}},
       {"unsigned long",{base,["int","unsigned","long"]}},
       {"long long",{base,["int","signed","longlong"]}},
       {"unsigned long long",{base,["int","unsigned","longlong"]}},
       {"float",{base,["float","signed","none"]}},
       {"double",{base,["double","signed","none"]}},
       {"void *",{base,["*","void","signed","none"]}},
       {"char *",{base,["*","char","signed","none"]}}
      ]).

get_derefed_type(Type, Module) ->
    Types = Module:get_types(),
    io:format("Module: ~p~n", [Module]),
    io:format("Type: ~p~n", [Type]),
    ResType = resolve_type(Type, Types),
    io:format("ResType: ~p~n", [ResType]),
    {_, TypeDef} = dict:fetch(ResType, Types),
    [H|_] = TypeDef,
    case (H=:="*") orelse (string:str(H, "[")>0) of
	true -> 
	    [_|Token] = lists:reverse(string:tokens(ResType, " ")),
	    NType = string:join(lists:reverse(Token), " "),
	    ResNType = resolve_type(NType, Types),
	    case dict:is_key(ResNType, Types) of
		true ->
		    {_, DTypeDef} = dict:fetch(ResNType, Types),
		    [DH|_] = DTypeDef,
		    case (DH=:="*") orelse (string:str(DH, "[")>0) of
			true -> {pointer, ResNType};
			false -> {final, ResNType}
		    end;
		false ->
		    undef
	    end;
	false ->
	    {final, ResType}
    end.

resolve_type(Type, Types) ->
    case dict:is_key(Type, Types) of 
	true ->
	    {Kind, TypeDef} = dict:fetch(Type, Types),
	    case Kind of
		typedef -> resolve_type(TypeDef, Types);
		_ -> Type
	    end;
	false ->
	    undef
    end.

%% pointer arithmetic
dereference(Pointer) ->
    {Address, ModuleType} = Pointer,
    [ModuleName, Type] = string:tokens(ModuleType, "."),
    Module = list_to_atom(ModuleName),
    case Module of
	nifty ->
	    build_builtin_type(Type, Address);
	_ ->
	    NType = get_derefed_type(Type, Module),
	    case NType of
		{pointer, NType} ->
		    {raw_deref(Address), ModuleName++"."++NType};
		{final, DType} ->
		    build_type(Module, DType, Address)
	    end
    end.

build_builtin_type(DType, Address) ->
    case DType of
	"void *" -> {raw_deref(Address), "undef"};
	"char *" -> cstr_to_list({Address, "nifty.char *"});
	_ -> build_type(nifty, DType, Address)
    end.

build_type(Module, Type, Address) ->
    Types = Module:get_types(),
    {Kind, Def} = dict:fetch(Type, Types),
    case Kind of
	userdef ->
	    [Name] = Def,
	    RR = dict:fetch(Name, Types),
	    case  RR of
		{struct, _} -> 
		    Module:erlptr_to_record({Address, Name});
		_ -> 
		    undef
	    end;
	base ->
	    case Def of
		["char", Sign, _] ->
		    int_deref(Address, 1, Sign);
		["int", Sign, L] ->
		    {_, {ShI, I, LI, LLI, _, _}} = proplists:lookup("sizes", get_config()),
		    Size = case L of
			       "short" ->
				   ShI;
			       "none" ->
				   I;
			       "long" ->
				   LI;
			       "longlong" ->
				   LLI
			   end,
		    int_deref(Address, Size, Sign);
		["float", _, _] ->
		    float_deref(Address);
		["double", _, _] ->
		    double_deref(Address);
		_ ->
		    undef
	    end;
	_ ->
	    undef
    end.

int_deref(Addr, Size, Sign) ->
    I = int_deref(mem_read({Addr, "nifty.void *"}, Size), 0),
    case Sign of
	"signed" ->
	    case I > (trunc(math:pow(2, Size-1))-1) of
		true -> 
		    I - trunc(math:pow(2,Size));
		false ->
		    I
	    end;
	"unsigned" ->
	    I
    end.

int_deref([], Acc) -> Acc;
int_deref([E|T], Acc) ->
    int_deref(T, (Acc bsl 8) + E).

-type addr() :: integer().
-type pointer() :: {addr(), nonempty_string()}.

-spec free(pointer()) -> 'ok'.
free({Addr, _}) ->
    raw_free(Addr).

%%% NIF Functions
-spec raw_free(addr()) -> 'ok'.
raw_free(_) ->
    erlang:nif_error(nif_library_not_loaded).

-spec float_deref(integer()) -> float().
float_deref(_) ->
    erlang:nif_error(nif_library_not_loaded).

-spec double_deref(integer()) -> float().
double_deref(_) ->    
    erlang:nif_error(nif_library_not_loaded).

%% string conversion
list_to_cstr(_) ->
    erlang:nif_error(nif_library_not_loaded).

cstr_to_list(_) ->
    erlang:nif_error(nif_library_not_loaded).

%% pointer arithmetic
pointer() ->
    {_, Size} = proplists:get_value("arch", nifty:get_config()),
    mem_alloc(Size).

pointer(Type) ->
    Types = get_types(),
    case dict:is_key(Type, Types) of
	true ->
	    Size = case dict:fetch(Type, Types) of
		       {base, ["char", _, _]} ->
			   1;
		       {base, ["int", _, L]} ->
			   {_, {ShI, I, LI, LLI, _, _}} = proplists:lookup("sizes", get_config()),
			   case L of
			       "short" ->
				   ShI;
			       "none" ->
				   I;
			       "long" ->
				   LI;
			       "longlong" ->
				   LLI
			   end;
		       {base, ["float", _, _]}->
			   {_, {_, _, _, _, Fl, _}} = proplists:lookup("sizes", get_config()),
			   Fl;
		       {base, ["double", _, _]}->
			   {_, {_, _, _, _, _, Dbl}} = proplists:lookup("sizes", get_config()),
			   Dbl;
		       {base, ["*"|_]} ->
			   {_, {_, P}} = proplists:lookup("arch", get_config()),
			   P
		   end,
	    as_type(mem_alloc(Size), nifty, Type);
	false ->
	    undefined
    end.

raw_pointer_of(_) ->
    erlang:nif_error(nif_library_not_loaded).

raw_deref(_) ->
    erlang:nif_error(nif_library_not_loaded).

%% memory operation
-spec mem_write(list()|binary()) -> pointer().
mem_write(Data) ->
    case erlang:is_binary(Data) of
	true ->
	    mem_writer(Data, mem_alloc(size(Data)));
	false ->
	    mem_write(Data, mem_alloc(length(Data)))
    end.

-spec mem_write(binary(), pointer()) -> pointer().
mem_write(_,_) ->
    erlang:nif_error(nif_library_not_loaded).

-spec mem_writer(list(), pointer()) -> pointer().
mem_writer(_,_) ->
    erlang:nif_error(nif_library_not_loaded).

-spec mem_read(pointer(), integer()) -> list().
mem_read(_,_) ->
    erlang:nif_error(nif_library_not_loaded).

-spec mem_alloc(non_neg_integer()) -> pointer().
mem_alloc(_) ->
    erlang:nif_error(nif_library_not_loaded).

%% config
get_config() ->
    exit(nif_library_not_loaded).

get_env() ->
    exit(nif_library_not_loaded).

as_type({Address, _}, Module, Type) ->
    case dict:is_key(Type, Module:get_types()) of
	true -> 
	    {Address, erlang:atom_to_list(Module)++"."++Type};
	false ->
	    undef
    end.
