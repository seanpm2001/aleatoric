# TODO Rewrite as a real parser using Treetop: http://treetop.rubyforge.org/

module Aleatoric
 
class ComposerASTException < Exception; end
 
class ComposerAST
 
  # Node nested class
  class ASTNode
    attr_reader :kw, :expr, :parent, :children
    
    def initialize(expr, kw='', parent=nil)
      @kw = kw
      @expr = expr
      @parent = parent
      @children = []
    end
    
    def add_child(node)
      @children << node
    end
    
    def to_s
      @expr
    end
  end  
  # /Node nested class
  
  # Class attributes that are the state and rules of the parse
  @@root = ASTNode.new(expr='root', kw='root', parent=nil)
      
  @@kw_completions = {
    'note' => " do\n",
    'phrase' => " do\n",
    'section' => " do\n",
    'repeat' => " do |index|\n",
    'write' => " do\n",
    'render' => " do\n",
    'format' => "\n",
    'def' => "\n",
    'measure' => " do\n",
    'copy_measure' => " do\n",
    'meter' => " do\n",
    'quantize' => "\n"
  }
  
  @@kw_block_close_completions= {
    'note' => "end\n",
    'phrase' => "end\n",
    'section' => "end\n",
    'repeat' => "end\n",
    'write' => "end\n",
    'render' => "end\n",
    'format' => "",
    'def' => "end\n",
    'measure' => "end\n",
    'copy_measure' => "end\n",
    'meter' => "end\n",
    'quantize' => ""
  }
    
  @@kw_children = {
    'root' => ['note', 'phrase', 'section', 'repeat', 'write', 'render', 'def', 'measure', 'copy_measure', 'meter'],
    'note' => [],
    'phrase' => ['note', 'repeat'],
    'section' => ['phrase', 'measure', 'copy_measure'],
    'repeat' => ['note', 'measure'],
    'write' => ['format'],
    'render' => [],
    'format' => [],
    'def' => [],
    'measure' => ['note'],
    'copy_measure' => [],
    'meter' => ['quantize'],
    'quantize' => []
  }
  @@kw_parents = {
    'root' => [],
    'note' => ['root', 'phrase', 'repeat', 'measure'],
    'phrase' => ['root', 'section'],
    'section' => ['root'],
    'repeat' => ['root', 'phrase'],
    'write' => ['root'],
    'render' => ['root'],
    'format' => ['write'],
    'def' => ['root'],
    'measure' => ['root', 'section', 'repeat'],
    'copy_measure' => ['root', 'section'],
    'meter' => ['root'],
    'quantize' => ['meter']
  }
  @@kw = @@kw_children.keys
 
  # TODO - only supports one arg, 'copy_measure' needs to validate two
	# TODO - Modified to support multiple args
  @@syntax_rules = {
    'note' =>     lambda {|x| x == nil or x[0] == nil or x[0].kind_of? String},     # 1st arg optional, valid type
    'phrase' => 	lambda {|x| x == nil or x[0] == nil or x[0].kind_of? String},     # 1st arg optional, valid type
    'section' => 	lambda {|x| x == nil or x[0] == nil or x[0].kind_of? String},     # 1st arg optional, valid type
    'repeat' => 	lambda {|x| x != nil and x[0] != nil and x[0].kind_of? Fixnum},                       		      # 1st arg required, valid type
    'render' => 	lambda {|x| x != nil and x[0] != nil and (x[0].kind_of? String and x[0].length > 0)},            # 1st arg required, valid type
    'write' => 		lambda {|x| x != nil and x[0] != nil and (x[0].kind_of? String and x[0].length > 0)},            # 1st arg required, valid type
    'format' => 	lambda {|x| x != nil and x[0] != nil and (x[0].to_s == 'csound' or x[0].to_s == 'midi')},        # 1st arg required, valid value
    'measure' => 	lambda {|x| x == nil or x[0] == nil or x[0].kind_of? String},     # 1st arg optional, valid type
    'copy_measure' => lambda {|x| x != nil and x.length == 2 and x[0] != nil and x[1] != nil and x[0].kind_of? String and x[1].kind_of? String},   # 1st and second arg required, valid types    
    'meter' =>    lambda {|x| x != nil and x.length == 2 and x[0] != nil and x[1] != nil and x[0].kind_of? Fixnum and x[1].kind_of? Fixnum},       # 1st and second arg required, valid types    
    'quantize' => lambda {|x| x != nil and x[0] != nil and (x[0].to_s == 'on' or x[0].to_s == 'off')}
  }
  
  @@grammar_rules = {
    'write' => lambda do |node|
      child_kws = node.children.collect {|child| child.kw}      
      child_kws.include? 'format'
    end, # 'write' has 'format' child
    'format' => lambda do |node|
      node.parent.kw == 'write'
    end  # 'format' has 'write' parent
  }
  
  @@operators = {:delim => [',', ';', "\n", '"'], 
                 :native_ruby => ['`','~','!','%','^','&&','&','*','(',')','-=', '-','+=','+','||','|','{','}','[',']'],
                 :assignment => ['=']
                }
  @@op_values = @@operators.values.flatten
	# NOTE: This includes the biggest hack ever, which supports 'NEXT' keyword by mapping it to the variable used to store
	#  current running start time dynamically when script is being evaluated
  @@var_map = {'NEXT' => '@cur_start'}
  @@assignment_states = [:declaring, :invoking]

  # NOTE: A hack to support testing. This must be first line in test scripts but it breaks the
  #  assignment preprocessing which assumes all assignment statements start the file.
  @@debug_stmts = ['reset_script_state']
    
  # /Class attributes that are the state and rules of the parse
  
   
  # Public parse interface
  def initialize
    @parent = @@root
  end
 
  def preprocess_script(src_file_name)
    script_lines = File.readlines src_file_name
    tkns = tokenize script_lines
		tkns = preprocess_assignment tkns
    tkns = preprocess_func tkns
    preprocess_expressions(tkns, src_file_name)
    self
  end
  
  # DFS the tree and print nodes pre-order.  This prints each line in order at
  #  each level of nesting, with all children printing after the opening line of their
  #  parent block and before the closing line of their parent block
  # note "note 1" do      # print block open, recurse
  #   amplitude 100       # print, recurse, leaf, back up, next
  #   pitch 150           # print, recurse, leaf, back up, next
  #   ...                 # back up
  # end                   # print block close, continue at this level of nesting
  def to_s  
    out_lines = []    
    out_lines = to_s_helper_validate_grammar(node=@@root, out_lines=[], line_no=0)    
    out_lines.join('')
  end
  # /Public parse interface
  
  # HELPERS
  private
  
  def tokenize(script_lines, op_list=nil)
    tkns = []    
    op_list ||= @@op_values
      # For each operator token, replace it with the token plus ws on each side of it
      # This lets us split the line and make sure all delimiting characters become their own token
      #  along with all 'words'.  Build up a list (one entry per line), of lists (each line a list of tkns)
      script_lines.each do |expr|
        op_list.each do |op|        
          expr.gsub!(op, ' ' + op + ' ')
        end
        # NOTE: This strips trailing '\n' which we will restore at the end of all line preprocessing
        expr_tkns = expr.split(' ').collect{|tkn| tkn.strip}            
        # Need this because strip() strips the "\n" that is there from line incoming
        # expr_tkns << "\n"
        expr_tkns = tokenize_join_str expr_tkns
        tkns << expr_tkns
      end
    tkns
  end
  
  def tokenize_join_str(tkns)    
    tkns_out = []
    str_expr_tkns = []
    str_delim_flag = false
    delim = ""
    tkns.length.times do |j|
      tkn = tkns[j]

      if ! str_delim_flag and (tkn != '"' and tkn != "'")
        tkns_out << tkn
      elsif ! str_delim_flag and (tkn == '"' or tkn == "'")
        str_delim_flag = true
        delim = tkn
      elsif (str_delim_flag && (tkn != delim))
        str_expr_tkns << tkn
      elsif (str_delim_flag && (tkn == delim))
        str_delim_flag = false
        expr = delim + str_expr_tkns.join(' ') + delim
        tkns_out << expr
        delim = ""
        str_expr_tkns = []
      end
    end
    
    tkns_out.flatten
  end

  def debug_stmt?(expr)
    expr.each do |tkn|
      return true if @@debug_stmts.include?(tkn)
    end
    false
  end
  
  def ass_replace_tkns_helper(tkn_line, lidx)
    (tkn_line.length - lidx).times do |j|
      idx = j + lidx
      @@var_map.each {|name, val| tkn_line[idx] = val if tkn_line[idx] == name}
    end
    tkn_line
  end
  
  def validate_skip_line(tkn_line)
    tkn_line == nil or tkn_line.length == 0 or tkn_line[0] == '"' or tkn_line[0] == "'" or tkn_line[0] == "#" or ((@@debug_stmts & tkn_line).length > 0)  
  end  
  
  def preprocess_assignment(tkns)
    state = :declaring    
    tkns_out = []
    
    tkns.each do |tkn_line|     
    # Skip comment lines, empty lines, special debug statemenets
      if not validate_skip_line tkn_line
        # Read all vars as a block at the start of the script, only support for vars right now        
        if state == :declaring
          if (tkn_line[0] == '"' || tkn_line[0] == "'" || tkn_line.length < 3 || tkn_line[1] != @@operators[:assignment][0])
            # First non-assignment statement, toggle state. This logic assumes all assignments
            #  at top of file, before anything else, so anything else stops binding names to vars            
            state = :invoking
          else          
            # Replace anything on right side with previously identified variables
            # So assignments can take previously declared vars as values
            lidx = 2 # because we are skipping ['x', '=', ...]
            tkn_line = ass_replace_tkns_helper(tkn_line, lidx)
            # Found an assignment, store value mapped to name, for substituting once state is :invocation                        
            @@var_map[tkn_line[0]] = tkn_line[2..tkn_line.length].join('')
          end
        # Not assigning vars so look for var invocations and substitute the value for the var name in the script
        else # if state == :invoking
          # For all the variables declared, sub the value for any appearance of the name in the expression
          lidx = 0
          tkn_line = ass_replace_tkns_helper(tkn_line, lidx)
        end
      end      
      tkns_out << tkn_line
    end
    
    tkns_out
  end

  def preprocess_func(tkns)  
    tkns_out = []
    tkns.each do |tkn_line|
      tkns_out << preprocess_func_helper(tkn_line)
		end
		tkns_out  
  end
  
  # Warning: this is a hack. Further proof that eventually this needs a real parser. 
  # Scanning instead of really building AST.  Only allowing nested functions as last args in parent expression
  def preprocess_func_helper(tkn_line)
    # Empty expr or expr is a string, or it has no colons then it's not a func dec or func call
    return tkn_line if validate_skip_line tkn_line
    num_tkns = tkn_line.size
    func_cnt = 0
    tkn_line_out = []
    num_tkns.times do |j|
      # Skipping length == 0 tkns, which should never happen since we stripped newlines
      #  and delimited on ws and made all deliting chars separate tokens
      tkn = tkn_line[j].strip
      next if tkn.length == 0
      # Do subsititutions for function tkns
      # Converts foo: a, b, c -> def foo(a,b,c)
      # Conerts instrument foo: a, b, c -> instrument foo(a,b,c)      
      if tkn.include?(':') and not tkn.include?('::') # [tkn.length - 1] == ':' and tkn.length > 1 and tkn[tkn.length - 2] != ':'
        func_cnt += 1
        tkn = tkn.sub(':', '(')
        # tkn_line[j] = tkn
        # If this is the first token in the line, then this is a function delcaration, do
        #  precede with 'def ' keyword so statement preprocessing that follows will make this a block
        tkn_line_out = ['def'] + tkn_line_out if j == 0
      end      
      tkn_line_out << tkn
    end
    # Put closing parens on end of statement
    # TODO This is lame because not a real tree, only supports nested function calls as last
    #  token in their subexpression
    func_cnt.times {tkn_line_out << ')'} if func_cnt > 0
    
    tkn_line_out
  end
	
	def preprocess_expressions(tkns, src_file_name)
	  line_no = 0
    tkns.each do |tkn_line|
      begin
        line_no += 1
        preprocess_expression(tkn_line, src_file_name, line_no)
      rescue Exception => e
        @parent.add_child(ASTNode.new(expr=e.to_s, kw='Composer_ERROR', parent=@parent))
        break      
      end
    end	
	end
  
  def preprocess_expression(tkn_line, src_file_name, line_no)  
    # Test for keyword starting line or not, kw lines processed differently because they
    #  create grammar structure of script, non-kw lines just appended to current parent as attrs of it
    is_kw, kw = kw? tkn_line[0]
        
    if is_kw
      # Validate special rules for this kw, raise error if violated
      is_valid = valid_kw_arg?(kw, tkn_line)
      if not is_valid
        raise ComposerASTException, "Source File Name: #{src_file_name}. Line Number: #{line_no}. Illegal argument '#{kw_arg}' passed to function '#{kw}'."
      end

      # Add the kw completion tokens to the end of the line
      tkn_line.insert(tkn_line.length, tokenize(@@kw_completions[kw]))
      
      # If kw is valid child of @parent, new more nested parent, add_new node as child of @parent
      #  and make it the new @parent
      if valid_child_kw?(parent=@parent.kw, child=kw)      
        new_node = insert_node(tkn_line, kw, @parent)
        @parent = new_node
      # If same as @parent or valid child of @parent.parent, add new_node 
      #  as next child of @parent.parent and make new_node the new @parent
      elsif @parent.kw == kw or valid_child_kw?(parent=@parent.parent.kw, child=kw)
        new_node = insert_node(tkn_line, kw, @parent.parent)
        @parent = new_node
      # Otherwise previous block ends and new block starts at a higher level. Nodes can be children 
      #  at multiple levels, and all can be child of root, so pop until first valid parent of new_node
      else
        found_parent = false
        cur_parent = @parent.parent
        while cur_parent != nil
          if valid_child_kw?(parent=cur_parent.kw, child=kw)
            new_node = insert_node(tkn_line, kw, cur_parent)
            @parent = new_node 
            found_parent = true
            break
          end
          cur_parent = cur_parent.parent
        end
        # If we get here, then we unwound to root, new node is new child of root, and new cur_parent
        if not found_parent
          if not root? cur_parent
            raise ComposerASTException, "Source File Name: #{src_file_name}. Line Number: #{line_no}. Illegal argument '#{kw_arg}' passed to function '#{kw}'."
          end
          new_node = insert_node(tkn_line, kw, cur_parent)
          @parent = new_node          
        end        
      end
    # Not a new grammar node, just an attribute node of the current parent, so just add child
    else    
      @parent.add_child(ASTNode.new(expr=tkns_to_expr(tkn_line, append_newline=true), kw='', parent=@parent))
    end    
  end
        
  def kw?(tkn)
    if @@kw.include? tkn
      return true, tkn
    else
      return false, nil
    end
  end
 
  def valid_kw_arg?(kw, kw_args)
    is_valid = true
    # kw_args is the slice of tkns after the first tkn, which is the keyword
    arg_tkns = nil
    arg_tkns = kw_args.slice(1, kw_args.length - 1) if kw_args != nil
    
    # If any args are a single comma, these are just delimiters for a list of args, so toss them
    arg_tkns_filtered = []
    arg_tkns.each {|arg_tkn| arg_tkns_filtered << arg_tkn if arg_tkn != ','}
		
    # Only test to convert int args if we actually need to call a validation function
    # And, obviously only go into block to call it if we need it
    syntax_rule = @@syntax_rules[kw]
    if syntax_rule != nil
      # So, some validation rules test for proper type or args passed, e.g. the loop bound
      #  value passed to 'repeat' which only makes sense as an Integer.  But all the args are
      #  being read in from a text file and not evaled so they look like strings.  So test
      #  if we can convert and do so and pass the Int if we can to the validation calls
      if arg_tkns_filtered != nil
        arg_tkns_filtered.length.times do |j|
          is_int, kw_arg_int = integer?(arg_tkns_filtered[j]) if arg_tkns_filtered[j] != nil
          arg_tkns_filtered[j] = kw_arg_int if is_int 
        end
      end
      is_valid = syntax_rule.call(arg_tkns_filtered) 
    end
    is_valid
  end
  
  def integer?(arg)
    if arg == nil
      return false, nil
    end
 
    # Integer() only throws on *strings* that aren't actually ints, e.g. Floats
    arg = arg.to_s    
    # Not the empty string and capable of being coerced by Integer()
    ret = nil
    is_int = false
    begin
      ret = Integer(arg)
      is_int = true
    rescue
      ret = nil
      is_int = false
    end
 
    return is_int, ret
  end
 
  def valid_child_kw?(parent, child)
    @@kw_children[parent].include? child
  end
  
  # TODO Get rid of this append_neline and put them back on in to_s!!!!
  def tkns_to_expr(tkns, append_newline=false)
    if append_newline
      tkns = tkns.join(' ') + "\n"
    else
      tkns = tkns.join(' ')
    end
  end
  
  def insert_node(tkns, kw, parent)
    new_node = ASTNode.new(tkns_to_expr(tkns, append_newline=true), kw, parent)
    parent.add_child(new_node)
    block_close_node = create_block_close_node(kw, parent)
    parent.add_child(block_close_node) unless block_close_node == nil
    new_node
  end  
  
	# This is not a standard accessor because want it only privat because should only be used for testing
	def root
		@@root
	end
	
  def root?(node)
    node.object_id == @@root.object_id
  end
  
  def create_block_close_node(kw, parent)
    # NOTE: This breaks if anything other than 'end\n' or something similar is block closer
    # Perhaps make more robust someday    
    close_expr = @@kw_block_close_completions[kw]
    if close_expr.length > 0
      close_kw = close_expr.strip
      ASTNode.new(expr=close_expr, kw=close_kw, parent=parent)
    else
      nil
    end
  end
  
  # /process_expr() Helpers
    
  # DFS the tree and print nodes pre-order. ... See comment above on to_s()
  # Also validate_grammar() called on each node because we are traversing finished tree
  #  and semantically cleaner code would mean traversing twice, once to validate and once to output
  def to_s_helper_validate_grammar(node, out_lines, line_no)  
    # Post-order append node to output
    s_out = node.to_s
    @@op_values.each do |op|
      s_out.gsub!(' ' + op, op) if op != '"'
      s_out.gsub!(op + ' ', op) if op != '"'
    end
    
    out_lines << s_out if s_out != 'root'
    # Loop over node's children
    node.children.each do |child|
      line_no += 1
      # Toss job if grammar rules violated      
      if not valid_grammar? child
        # TEMP DEBUG
        pp(@@root, [], 0)
        
        raise ComposerASTException, "Line Number: #{line_no}. Illegal structure. Node '#{child.kw}' has an illegal parent or child"
      end
      
      # Else recurse on each child, DFS
      to_s_helper_validate_grammar(child, out_lines, line_no)
    end
    # Return list of output lines
    out_lines
  end
  
  def valid_grammar?(node)
    is_valid = true
    grammar_rule = @@grammar_rules[node.kw]
    is_valid = grammar_rule.call(node) if grammar_rule != nil
    is_valid
  end
  
  def pp(node, out_lines, depth)
    # Return list of output lines
    outlines = pp_helper(node, out_lines, depth)
    puts "\n\nTREE"
    puts out_lines
    puts "\TREE\n\n"
  end
  
  def pp_helper(node, out_lines, depth)
    # Preorder append node to output
    pad = ''
    depth.times {pad = pad + '-'}
    out_lines << pad + node.to_s
    node.children.each do |child|
      pp_helper(child, out_lines, depth + 1)
    end
  end
 
  # /HELPERS
 
end
 
end
