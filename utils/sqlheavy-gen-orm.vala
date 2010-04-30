namespace SQLHeavy {
  public errordomain GeneratorError {
    CONFIGURATION,
    METADATA,
    SYMBOL_RESOLVER,
    DATABASE,
    SELECTOR
  }

  public class Generator : GLib.Object {
    [CCode (array_length = false, array_null_terminated = true)]
    static string[] sources;
    [CCode (array_length = false, array_null_terminated = true)]
    static string[] vapi_directories;
    [CCode (array_length = false, array_null_terminated = true)]
    static string[] packages;
    static string metadata_location;
    static string output_location;
    static bool write_properties;

    private Vala.CodeContext context = new Vala.CodeContext ();
    private GLib.SList<string> databases = new GLib.SList<string> ();

    const GLib.OptionEntry[] options = {
      { "metadata", 'm', 0, OptionArg.FILENAME, ref metadata_location, "Load metadata from FILE", "FILE..." },
      { "vapidir", 0, 0, OptionArg.FILENAME_ARRAY, ref vapi_directories, "Look for package bindings in DIRECTORY", "DIRECTORY..." },
      { "pkg", 0, 0, OptionArg.STRING_ARRAY, ref packages, "Include binding for PACKAGE", "PACKAGE..." },
      { "output", 'o', 0, OptionArg.FILENAME, ref output_location, "Output to FILE (default is stdout)", "FILE..." },
      { "properties", 'p', 0, GLib.OptionArg.NONE, ref write_properties, "Write properties instead of methods", null },
      { "", 0, 0, OptionArg.FILENAME_ARRAY, ref sources, "SQLite databases", "DATABASE..." },
      { null }
    };

    private Vala.HashMap<string, Vala.HashMap <string, string>> cache =
      new Vala.HashMap<string, Vala.HashMap <string, string>> (GLib.str_hash, GLib.str_equal);
    private Vala.HashMap<string, Vala.HashMap <string, string>> wildcard_cache =
      new Vala.HashMap<string, Vala.HashMap <string, string>> (GLib.str_hash, GLib.str_equal);

    private Vala.HashMap <string, string> get_symbol_properties (string symbol) {
      var map = this.cache.get (symbol);
      if ( map != null )
        return map;

      map = new Vala.HashMap<string,string> (GLib.str_hash, GLib.str_equal, GLib.str_equal);
      foreach ( string selector in this.wildcard_cache.get_keys () ) {
        if ( GLib.PatternSpec.match_simple (selector, symbol) ) {
          var wmap = this.wildcard_cache.get (selector);
          foreach ( string key in wmap.get_keys () )
            map.set (key, wmap.get (key));
        }
      }

      this.cache.set (symbol, map);
      return map;
    }

    private void set_symbol_property (string symbol, string key, string value) {
      this.get_symbol_properties (symbol).set (key, value);
    }

    private string? get_symbol_property (string symbol, string key) {
      return this.get_symbol_properties (symbol).get (key);
    }

    private string get_symbol_name (string symbol) {
      string? sym = this.get_symbol_property (symbol, "name");
      if ( sym != null )
        return sym;

      int sym_t = 3;
      bool tb = true, sb = true, tf = true;
      GLib.StringBuilder name = new GLib.StringBuilder.sized (symbol.size () * 2);
      for ( sym = symbol ; ; sym = sym.offset (1) ) {
        var c = sym.get_char_validated ();
        if ( c <= 0 )
          break;

        if ( sb ) {
          if ( c == '@' ) {
            sym_t = 1;
            continue;
          } else if ( c == '%' ) {
            sym_t = 2;
            continue;
          }
        }

        if ( c == '_' ) {
          tb = true;
          tf = true;
          continue;
        } else if ( c == '/' ) {
          sym_t = int.min (3, sym_t + 1);
          tf = tb = sb = true;
          name.truncate (0);
          continue;
        }

        if ( c.isupper () && !tb ) {
          if ( sym_t == 3 )
            name.append_c ('_');
          tb = true;
          tf = false;
          name.append_unichar (sym_t == 3 ? c.tolower () : c.toupper ());
          continue;
        } else if ( c.islower () && tb ) {
          if ( tf && sym_t != 3 )
            name.append_unichar (c.toupper ());
          else if ( tf && !sb && sym_t == 3 ) {
            name.append_c ('_');
            name.append_unichar (c);
          }
          else
            name.append_unichar (c);
          tb = tf = false;
          continue;
        }

        sb = false;
        name.append_unichar (tb ? (sym_t == 3 ? c.tolower () : c.toupper ()) : c.tolower ());
        tf = false;
      }

      this.set_symbol_property (symbol, "name", name.str);
      return name.str;
    }

    public bool symbol_is_hidden (string symbol) {
      var p = this.get_symbol_property (symbol, "hidden");
      return p != null && (p == "1" || p == "true" || p == "yes");
    }

    private static Vala.DataType type_from_string (string datatype) {
      bool is_array = false;
      var internal_datatype = datatype;
      Vala.UnresolvedSymbol? symbol = null;

      if ( datatype.has_suffix ("[]") ) {
        internal_datatype = internal_datatype.substring (0, -2);
        is_array = true;
      }

      foreach ( unowned string m in internal_datatype.split (".") )
        symbol = new Vala.UnresolvedSymbol (symbol, m);

      var data_type = new Vala.UnresolvedType.from_symbol (symbol);
      if ( is_array )
        return new Vala.ArrayType (data_type, 1, null);
      else
        return data_type;
    }

    private Vala.DataType? get_data_type (string symbol) {
      string? name = this.get_symbol_property (symbol, "type");

      return name == null ? null : type_from_string (name);
    }

    private void visit_field (SQLHeavy.Table table, int field, Vala.Class cl) throws GeneratorError, SQLHeavy.Error {
      var db = table.queryable.database;
      var db_symbol = GLib.Path.get_basename (db.filename).split (".", 2)[0];
      var symbol = @"@$(GLib.Path.get_basename (db_symbol))/$(table.name)/$(table.field_name (field))";
      var name = this.get_symbol_name (symbol);

      if ( this.symbol_is_hidden (symbol) )
        return;

      var data_type = this.get_data_type (symbol);
      if ( data_type == null ) {
        var affinity = table.field_affinity (field).down ().split (" ");

        if ( affinity[0] == "integer" )
          affinity[0] = "int";
        else if ( affinity[0] == "text" ||
                  affinity[0].has_prefix ("varchar") ||
                  affinity[0].has_prefix ("char") )
          affinity[0] = "string";
        else if ( affinity[0] == "blob" )
          affinity[0] = "uint8[]";

        data_type = type_from_string (affinity[0]);
      }

      var data_type_get = data_type.copy ();
      data_type_get.value_owned = true;

      if ( !write_properties ) {
        {
          var get_method = new Vala.Method (@"get_$(name)", data_type_get);
          cl.add_method (get_method);
          get_method.access = Vala.SymbolAccessibility.PUBLIC;
          get_method.add_error_type (type_from_string ("SQLHeavy.Error"));

          var block = new Vala.Block (null);
          var call = new Vala.MethodCall (new Vala.MemberAccess (new Vala.StringLiteral ("this"), @"fetch_named_$(data_type_get.to_string ())"));
          call.add_argument (new Vala.StringLiteral (@"\"$(table.field_name (field))\""));
          block.add_statement (new Vala.ReturnStatement (call));

          get_method.body = block;
        }

        {
          var set_method = new Vala.Method (@"set_$(name)", new Vala.VoidType ());
          set_method.add_parameter (new Vala.FormalParameter ("value", data_type));
          cl.add_method (set_method);
          set_method.access = Vala.SymbolAccessibility.PUBLIC;
          set_method.add_error_type (type_from_string ("SQLHeavy.Error"));

          var block = new Vala.Block (null);
          var call = new Vala.MethodCall (new Vala.MemberAccess (new Vala.StringLiteral ("this"), @"put_named_$(data_type.to_string ())"));
          call.add_argument (new Vala.StringLiteral (@"\"$(table.field_name (field))\""));
          block.add_statement (new Vala.ExpressionStatement (call));

          set_method.body = block;
        }
      } else {
        Vala.PropertyAccessor get_accessor, set_accessor;
        {
          var block = new Vala.Block (null);
          var try_block = new Vala.Block (null);
          var catch_block = new Vala.Block (null);
          var try_stmt = new Vala.TryStatement (try_block, null, null);

          var call = new Vala.MethodCall (new Vala.MemberAccess (new Vala.StringLiteral ("this"), @"fetch_named_$(data_type_get.to_string ())"));
          call.add_argument (new Vala.StringLiteral (@"\"$(table.field_name (field))\""));
          try_block.add_statement (new Vala.ReturnStatement (call));

          var error_call = new Vala.MethodCall (new Vala.MemberAccess (new Vala.StringLiteral ("GLib"), "error"));
          error_call.add_argument (new Vala.StringLiteral (@"\"Unable to retrieve `$(name)': %s\""));
          error_call.add_argument (new Vala.MemberAccess (new Vala.MemberAccess (null, "e"), "message"));
          catch_block.add_statement (new Vala.ExpressionStatement (error_call));

          try_stmt.add_catch_clause (new Vala.CatchClause (type_from_string ("SQLHeavy.Error"), "e", catch_block, null));
          block.add_statement (try_stmt);

          get_accessor = new Vala.PropertyAccessor (true, false, false, data_type_get, block, null);
        }

        {
          var block = new Vala.Block (null);
          var try_block = new Vala.Block (null);
          var catch_block = new Vala.Block (null);
          var try_stmt = new Vala.TryStatement (try_block, null, null);

          var call = new Vala.MethodCall (new Vala.MemberAccess (new Vala.StringLiteral ("this"), @"put_named_$(data_type_get.to_string ())"));
          call.add_argument (new Vala.StringLiteral (@"\"$(table.field_name (field))\""));
          call.add_argument (new Vala.MemberAccess (null, "value"));
          try_block.add_statement (new Vala.ExpressionStatement (call));

          var error_call = new Vala.MethodCall (new Vala.MemberAccess (new Vala.StringLiteral ("GLib"), "error"));
          error_call.add_argument (new Vala.StringLiteral (@"\"Unable to set `$(name)': %s\""));
          error_call.add_argument (new Vala.MemberAccess (new Vala.MemberAccess (null, "e"), "message"));
          catch_block.add_statement (new Vala.ExpressionStatement (error_call));

          try_stmt.add_catch_clause (new Vala.CatchClause (type_from_string ("SQLHeavy.Error"), "e", catch_block, null));
          block.add_statement (try_stmt);

          set_accessor = new Vala.PropertyAccessor (false, true, false, data_type, block, null);
        }

        var prop = new Vala.Property (name, data_type, get_accessor, set_accessor);
        cl.add_property (prop);
      }
    }

    private void visit_table (SQLHeavy.Table table, Vala.Namespace ns) throws GeneratorError, SQLHeavy.Error {
      var db = table.queryable.database;
      var db_symbol = GLib.Path.get_basename (db.filename).split (".", 2)[0];
      var symbol = @"@$(GLib.Path.get_basename (db_symbol))/$(table.name)";
      var symbol_name = this.get_symbol_name (symbol);

      if ( this.symbol_is_hidden (symbol) ) { }
      //return;

      var cl = ns.scope.lookup (symbol_name) as Vala.Class;

      if ( cl == null ) {
        cl = new Vala.Class (symbol_name);
        cl.access = Vala.SymbolAccessibility.PUBLIC;
        ns.add_class (cl);
      }

      cl.add_base_type (type_from_string ("SQLHeavy.Row"));

      for ( var field = 0 ; field < table.field_count ; field++ ) {
        this.visit_field (table, field, cl);
      }
    }

    private void visit_database (SQLHeavy.Database db) throws GeneratorError {
      var symbol = "@".concat (GLib.Path.get_basename (db.filename).split (".", 2)[0]);
      var symbol_name = this.get_symbol_name (symbol);
      Vala.Namespace? ns = this.context.root.scope.lookup (symbol_name) as Vala.Namespace;

      if ( ns == null ) {
        ns = new Vala.Namespace (symbol_name, null);
        this.context.root.add_namespace (ns);
      }

      if ( this.symbol_is_hidden (symbol) )
        return;

      try {
        var tables = db.get_tables ();
        foreach ( unowned SQLHeavy.Table table in tables.get_values () ) {
          this.visit_table (table, ns);
        }
      } catch ( SQLHeavy.Error e ) {
        throw new GeneratorError.DATABASE ("Database error: %s", e.message);
      }
    }

    public void run () throws GeneratorError {
      var parser = new Vala.Parser ();
      parser.parse (this.context);

      foreach ( unowned string dbfile in this.databases ) {
        SQLHeavy.Database db;
        try {
          db = new SQLHeavy.Database (dbfile, SQLHeavy.FileMode.READ);
        } catch ( SQLHeavy.Error e ) {
          throw new GeneratorError.CONFIGURATION ("Unable to open database: %s", e.message);
        }
        this.visit_database (db);
      }

      var resolver = new Vala.SymbolResolver ();
      resolver.resolve (context);

      if (context.report.get_errors () > 0)
        throw new GeneratorError.SYMBOL_RESOLVER ("Error resolving symbols.");

      var analyzer = new Vala.SemanticAnalyzer ();
      analyzer.analyze (context);

      var code_writer = new Vala.CodeWriter (true);
      code_writer.write_file (this.context, output_location ?? "/dev/stdout");
    }

    private void add_package (string pkg) throws GeneratorError {
      if ( this.context.has_package (pkg) )
        return;

      var package_path = this.context.get_package_path (pkg, vapi_directories);
      if ( package_path == null )
        throw new GeneratorError.CONFIGURATION (@"Could not find package '$(pkg)'");

      this.context.add_package (pkg);
      this.context.add_source_file (new Vala.SourceFile (this.context, package_path, true));

      var deps_filename = GLib.Path.build_filename (GLib.Path.get_dirname (package_path), "%s.deps".printf (pkg));
      if ( GLib.FileUtils.test (deps_filename, GLib.FileTest.EXISTS) ) {
        try {
          string deps_content;
          size_t deps_len;
          GLib.FileUtils.get_contents (deps_filename, out deps_content, out deps_len);
          foreach ( string dep in deps_content.split ("\n") )
            if ( dep.strip () != "" )
              this.add_package (dep);
        } catch ( GLib.FileError e ) {
          throw new GeneratorError.CONFIGURATION (@"Unable to read dependency file: $(e.message)");
        }
      }
    }

    private static string parse_selector (string selector, out bool wildcard) throws GeneratorError {
      wildcard = false;
      string?[] real_selector = new string[3];
      var segments = selector.split ("/", 3);

      int pos = 0;
      for ( int seg = 0 ; seg < segments.length ; seg++ ) {
        var first_char = segments[seg].get_char ();

        if ( first_char == '%' || first_char == '@' ) {
          int dest_pos;
          if ( first_char == '%' ) {
            segments[seg] = segments[seg].offset (1);
            dest_pos = 1;
          }
          else
            dest_pos = 0;

          while ( pos < dest_pos ) {
            wildcard = true;
            real_selector[pos] = "*";
            pos++;
          }
        } else if ( pos == 0 && first_char != '*' ) {
          wildcard = true;
          real_selector[0] = "*";
          real_selector[1] = "*";
          pos = 2;
        }

        if ( segments[seg] == "*" )
          wildcard = true;

        if ( pos > 2 || real_selector[pos] != null )
          throw new GeneratorError.SELECTOR ("Invalid selector (%s).", selector);
        real_selector[pos] = segments[seg];
        pos++;
      }

      return string.joinv ("/", real_selector);
    }

    private void parse_metadata () throws GeneratorError, GLib.KeyFileError {
      var metadata = new GLib.KeyFile ();
      metadata.load_from_file (metadata_location, GLib.KeyFileFlags.NONE);

      foreach ( unowned string group in metadata.get_groups () ) {
        bool is_wildcard;
        var selector = parse_selector (group, out is_wildcard);

        var cache = is_wildcard ? this.wildcard_cache : this.cache;
        var properties = cache.get (selector);
        if ( properties == null ) {
          properties = new Vala.HashMap<string, string> (GLib.str_hash, GLib.str_equal, GLib.str_equal);
          cache.set (selector, properties);
        }

        foreach ( unowned string key in metadata.get_keys (group) )
          properties.set (key, metadata.get_string (group, key));
      }
    }

    public void configure () throws GeneratorError {
      if ( metadata_location != null ) {
        try {
          this.parse_metadata ();
        } catch ( GLib.KeyFileError e ) {
          throw new GeneratorError.CONFIGURATION ("Unable to load metadata file: %s", e.message);
        } catch ( GLib.FileError e ) {
          throw new GeneratorError.CONFIGURATION ("Unable to load metadata file: %s", e.message);
        }
      }

      this.context.profile = Vala.Profile.GOBJECT;
      Vala.CodeContext.push (this.context);

      // Default packages
      this.add_package ("glib-2.0");
      this.add_package ("gobject-2.0");
      this.add_package ("sqlheavy-1.0");

      foreach ( unowned string pkg in packages ) {
        this.add_package (pkg);
      }

      foreach ( unowned string source in sources ) {
        if ( source.has_suffix (".vala") ) {
          if ( GLib.FileUtils.test (source, GLib.FileTest.EXISTS) )
            this.context.add_source_file (new Vala.SourceFile (this.context, source));
          else
            throw new GeneratorError.CONFIGURATION (@"Source file '$(source)' does not exist.");
        } else {
          this.databases.prepend (source);
        }
      }
    }

    private static int main (string[] args) {
      try {
        var opt_context = new GLib.OptionContext ("- SQLHeavy ORM Generator");
        opt_context.set_help_enabled (true);
        opt_context.add_main_entries (options, null);
        opt_context.set_summary ("This tool will generate a Vala file which provides an object for each\ntable in the specified database(s), each of which provides an object for each\ntable in the specified database(s), each of which extends the\nSQLHeavyRecord class.");
        opt_context.set_description ("Copyright 2010 Evan Nemerson.\nReleased under versions 2.1 and 3 of the LGPL.\n\nFor more information, or to report ed under versions 2.1 and 3 of the LGPL.\n\nFor more information, or to report a bug, see\n<http://code.google.com/p/sqlheavy>");

        opt_context.parse (ref args);
      } catch ( GLib.OptionError e ) {
        GLib.stdout.puts (@"$(e.message)\n");
        GLib.stdout.puts (@"Run '$(args[0]) --help' to see a full list of available command line options.\n");
        return 1;
      }

      if ( sources == null ) {
        GLib.stderr.puts ("No databases specified.\n");
        return 1;
      }

      var generator = new Generator ();
      try {
        generator.configure ();
        generator.run ();
      } catch ( GeneratorError e ) {
        GLib.stderr.puts (@"Error: $(e.message)\n");
        GLib.stdout.puts (@"Run '$(args[0]) --help' to see a full list of available command line options.\n");
        return 1;
      }

      return 0;
    }
  }
}
