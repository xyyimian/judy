module RunTime

include("DebugInfo.jl")

mutable struct BreakPoints
  filepath::AbstractString
  lineno::Array{Int64,1}
end

mutable struct AstInfo
  asts::Array
  blocks::Array # save struct BlockInfo
end

mutable struct BlockInfo
  BlockType::Symbol
  startline::Int64
  endline::Int64
  raw_code::AbstractString
end

# FileLine["FileName"] = line number
FileLine = Dict()
# FileAst["filename"] = struct AstInfo
FileAst = Dict()
# FileBp["filename"] = [bp line array]
FileBp = Dict()
# run file stack for `include`
RunFileStack = []

EntryFile = ""
errors = ""

struct NotImplementedError <: Exception end
struct BreakPointStop <: Exception end

# entry file for debugging
function setEntryFile(file)
  global RunFileStack
  global FileLine
  global EntryFile
  EntryFile = abspath(file)
  push!(RunFileStack, EntryFile)
  readSourceToAST(EntryFile)
end

function readSourceToAST(file)
  global FileAst
  global FileLine
  asts = []
  blocks = []
  line = 0
  s = ""
  # recording blocks such as a function
  block_start = 0
  block_end = 0
  open(file) do f
    for ln in eachline(f)
      line += 1
      s *= ln
      ex = parseInputLine(s)
      if (isa(ex, Expr) && ex.head === :incomplete)
        s *= "\n"
        if block_start == 0
          block_start = line
        end
        continue
      else
        if block_start != 0
          # add block line postion
          block_end = line
          blockinfo = BlockInfo(ex.head, block_start, block_end, s)
          push!(blocks, blockinfo)
          block_start = 0
        end
        ast = Meta.lower(Main, ex)
        push!(asts, ast)
        s = ""
      end
    end
  end
  FileAst[file] = AstInfo(asts, blocks)
  if !haskey(FileLine, file)
    FileLine[file] = 1
  end
end

# run whole program
# return a status contains ast, current_line
function run() 
  global FileLine
  global FileAst
  global RunFileStack
  global EntryFile
  # reset all file line
  RunFileStack = []
  push!(RunFileStack, EntryFile)
  for file in FileLine
    FileLine[file] = 1
  end
  # start running program
  println(EntryFile)
  for ast in FileAst[RunFileStack[end]].asts
    try
      if !tryRunNewFile(ast)
        Core.eval(Main, ast)
        updateLine()
      else
        return
      end
    catch err
      # if we run to a breakpoint
      # we will catch an exception and collect info
      if err isa BreakPointStop
        Break()
      else
        println(err)
      end
      return
    end
  end
  # exit normally
  pop!(RunFileStack)
  if length(RunFileStack) != 0
    continous()
  end
  return
end

# check whether is `include` call
# if it is & included file has breakpoints,
# we manually run it
function tryRunNewFile(ast, isStepOver = false)
  global RunFileStack
  local isIncludeCall = false
  local filename = ""
  try
    if ast.args[1].code[1].args[1] == (:include)
      filename = abspath(joinpath(RunFileStack[end], "../" * ast.args[1].code[1].args[2]))
      isIncludeCall = true
    end
  catch err
    # we may get bounderror
    return false
  end
  if isIncludeCall
    if !haskey(FileAst, filename)
      # in this case: no breakpoint has been set to this file
      # we just use eval to run include call
      return false
    else
      # skip include call (we run it manually)
      println("detect include file: $(filename)")
      updateLine()
      push!(RunFileStack, filename)
      FileLine[filename] = 1
      continous(isStepOver)
    end
  end
  return isIncludeCall
end
    

# update info from this point
function Break()
  # debug info
  global RunFileStack
  global FileLine
  # current_line = FileLine[RunFileStack[end]]
  println(stacktrace())
  current_line = stacktrace()[2].line
  FileLine[RunFileStack[end]] = current_line

  println("hit breakpoint: $(RunFileStack[end]): $(current_line)")
  # collect variable info
  DebugInfo.collectVarInfo()
  # collect stack info
  DebugInfo.collectStackInfo()
end


# go to next line
# if next line is an empty line, 
# we ignore this line and go until it's a valid ast
function stepOver()
  global FileAst
  global FileLine
  global RunFileStack
  current_file = RunFileStack[end]
  asts = FileAst[current_file].asts
  ast_index = getAstIndex(current_file, FileLine[current_file])
  if ast_index == lastindex(asts) + 1
    pop!(RunFileStack)
    return false
  end
  # run next line code
  if asts[ast_index] isa Nothing
    # if we find a blank line, we skip it
    updateLine()
    stepOver()
  end
  # true line
  try
    if !tryRunNewFile(ast, true)
      Core.eval(Main, asts[ast_index])
      updateLine()
    else
      return true
    end
  catch err
    if err isa BreakPointStop
      Break()
      return true
    else
      global errors
      errors = string(err)
      println(errors)
      return false
    end
  end
  Break()
  return true
end

# go until we meet a bp
function continous(stopOnPopFile = false)
  global FileAst
  global FileLine
  global RunFileStack
  current_file = RunFileStack[end]
  asts = FileAst[current_file].asts
  ast_index = getAstIndex(current_file, FileLine[current_file])

  res = Dict("allThreadsContinued" => true)

  for ast in asts[ast_index: end]
    try
      if !tryRunNewFile(ast)
        if ast isa Nothing
          continue
        else
          println(ast)
        end
        Core.eval(Main, ast)
        updateLine()
      else
        return res
      end
    catch err
      if err isa BreakPointStop
        Break()
      else
        global errors
        errors = string(err)
        println("runtime errors: $(errors)")
      end
      return res
    end
  end
  # exit normally
  pop!(RunFileStack)
  if !stopOnPopFile && length(RunFileStack) != 0
    res = continous()
  end
  return res
end

function stepIn()
  throw(NotImplementedError("step has not been implemented"))
end

# set breakpoint
# if breakpoint is on blank line,
# it will not be set

function setBreakPoints(filepath, lineno)
  global FileBp
  global FileAst
  result = []
  filepath = abspath(filepath)
  readSourceToAST(filepath)
  FileBp[filepath] = []
  asts = FileAst[filepath].asts
  id = 1

  for bpline in lineno
    ast, ofs, realLineno = getRealPos(filepath, bpline)
    print(realLineno)
    index = findfirst(isequal(bpline), lineno)
    lineno[index] = realLineno
    push!(result, Dict("verified" => true,
    "line" => realLineno,  #verify first non-blank line
    "id" => id))
    id += 1
    if !isequal(Nothing,ast)
      ast.args[2].args[ofs] = Expr(:call, Break)
      eval(ast)
    end
  end

  FileBp[filepath] = lineno
  return result
end

function getRealPos(filepath, bpline)
  global FileAst
  global RunFileStack
  asts = FileAst[filepath].asts
  blocks = FileAst[filepath].blocks
    #check if exists bp in block
    #The key to insert the point is when we revise a copy of function's ast,
    #and then eval the ast, we update the definition of the function
    #Another thing is we should make the mapping from original code pos to insert offset
    #considering blank line  
  for blockinfo in blocks
    if blockinfo.startline <= bpline <= blockinfo.endline
      ast = parseInputLine(blockinfo.raw_code)
      codelines = split(blockinfo.raw_code,"\n")
      # for codeline in codelines:
      #   if isempty(strip(codeline))
      nonBlankLine = 0
      firstNonBlankLine = 0
      for i in range(1, stop = blockinfo.endline - blockinfo.startline + 1)
        if isempty(strip(codelines[i]))
          continue
        end
        if i >= bpline - blockinfo.startline + 1
          firstNonBlankLine = i
          break
        end
        nonBlankLine += 1  #nonBlankLine before bp line
      end
      push!(ast.args[2].args, Nothing)
      if nonBlankLine == 0
        ofs = 1
      elseif bpline == blockinfo.endline
        firstNonBlankLine = blockinfo.endline - blockinfo.startline + 1
        ofs = length(ast.args[2].args)
      else
        ofs = 2 * nonBlankLine - 1
      end
      realLineno = firstNonBlankLine + blockinfo.startline - 1
      return ast, ofs, realLineno
    #not in a block
    end
  end

  firstNonBlankLine = bpline
  while true
    ast_index = getAstIndex(filepath, firstNonBlankLine)
    if ast_index > length(asts)
      firstNonBlankLine = bpline
      break
    end
    if asts[ast_index] isa Nothing
      firstNonBlankLine += 1
    else
      break
    end
  end
  return Nothing, Nothing, firstNonBlankLine
end   


# update line for run/next/continous call
function updateLine()
  global RunFileStack
  global FileLine
  global FileAst
  current_file = RunFileStack[end]
  blocks = FileAst[current_file].blocks
  while FileAst[current_file].asts[getAstIndex(current_file, FileLine[current_file])] isa Nothing
    FileLine[current_file] += 1
  end
  ofs = 1     #------------to be modified
  for blockinfo in blocks
    if FileLine[current_file] == blockinfo.startline
      ofs += blockinfo.endline - blockinfo.startline + 1
      break
    elseif blockinfo.startline > FileLine[current_file]
      break
    end
  end
  FileLine[current_file] += ofs
  println("next line", FileLine[current_file])
  if checkBreakPoint()
    throw(BreakPointStop())
  end
end

# check whether current line meets a bp
function checkBreakPoint()
  global RunFileStack
  global FileLine
  global FileBp
  current_file = RunFileStack[end]
  current_line = FileLine[RunFileStack[end]]
  ast, ofs, realLineno = getRealPos(current_file, current_line)
  FileLine[current_file] = realLineno
  print("in checkbp ", FileLine[current_file])
  if realLineno in FileBp[current_file]
    return true
  else
    return false
  end
end

# get AstIndex from current file and line number
function getAstIndex(filepath, lineno)
  global FileAst
  blocks = FileAst[filepath].blocks
  base = lineno
  ofs = 0
  for block in blocks
    if block.startline <= lineno <= block.endline
      base = block.startline
      break
    elseif block.startline > lineno
      break
    end
    ofs += block.endline - block.startline
  end
  return base - ofs
end

function parseInputLine(s::String; filename::String="none", depwarn=true)
  # For now, assume all parser warnings are depwarns
  ex = if depwarn
      ccall(:jl_parse_input_line, Any, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
            s, sizeof(s), filename, sizeof(filename))
  else
      with_logger(NullLogger()) do
          ccall(:jl_parse_input_line, Any, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                s, sizeof(s), filename, sizeof(filename))
      end
  end
  return ex
end

end # module RunTime 