module dfix;

import std.experimental.lexer;
import dparse.lexer;
import dparse.parser;
import std.stdio;
import std.format;
import std.file;

import dfixvisitor;
import markers;
import dfixutils;
import skiputils;

import dparse.ast;

int main(string[] args)
{
	import std.getopt : getopt;
	import std.parallelism : parallel;

	// http://wiki.dlang.org/DIP64
	bool dip64;
	// http://wiki.dlang.org/DIP65
	bool dip65 = true;
	//https://github.com/dlang/DIPs/blob/master/DIPs/DIP1003.md
	bool dip1003 = true;

	bool help;

	try
	{
		getopt(args, "dip64", &dip64, "dip65", &dip65, "dip1003", &dip1003, "help|h", &help);
	}
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}

	if (help)
	{
		printHelp();
		return 0;
	}

	if (args.length < 2)
	{
		stderr.writeln("File path is a required argument");
		return 1;
	}

	string[] files;

	foreach (arg; args[1 .. $])
	{
		if (isDir(arg))
		{
			foreach (f; dirEntries(arg, "*.{d,di}", SpanMode.depth))
				files ~= f;
		}
		else
			files ~= arg;
	}

	foreach (f; parallel(files))
	{
		try
		upgradeFile(f, dip64, dip65, dip1003);
		catch (Exception e)
		stderr.writeln("Failed to upgrade ", f, ":(", e.file, ":", e.line, ") ", e.msg);
	}

	return 0;
}

/**
 * Fixes the given file.
 */
void upgradeFile(string fileName, bool dip64, bool dip65, bool dip1003)
{
	import std.algorithm : filter, canFind;
	import std.range : retro;
	import std.array : array, uninitializedArray;
	import dparse.formatter : Formatter;
	import std.exception : enforce;
	import dparse.rollback_allocator : RollbackAllocator;
	import std.functional : toDelegate;

	ubyte[] fileBytes = readFile(fileName);

	StringCache cache = StringCache(StringCache.defaultBucketCount);
	LexerConfig config;
	config.fileName = fileName;
	config.stringBehavior = StringBehavior.source;
	auto tokens = byToken(fileBytes, config, &cache).array;
	auto parseTokens = tokens.filter!(
		a => a != tok!"whitespace" && a != tok!"comment" && a != tok!"specialTokenSequence"
	).array;

	RollbackAllocator allocator;
	uint errorCount;
	auto mod = parseModule(parseTokens, fileName, &allocator, toDelegate(&reportErrors), &errorCount);
	if (errorCount > 0)
	{
		stderr.writefln("%d parse errors encountered. Aborting upgrade of %s",
		errorCount, fileName);
		return;
	}

	File output = File(fileName, "wb");
	auto visitor = new DFixVisitor;
	visitor.visit(mod);
	relocateMarkers(visitor.markers, tokens);

	SpecialMarker[] markers = visitor.markers;

	auto formatter = new Formatter!(File.LockingTextWriter)(File.LockingTextWriter.init);

	void writeType(T)(File output, T tokens, ref size_t i)
	{
		if (isBasicType(tokens[i].type))
		{
			writeToken(output, tokens[i]);
			i++;
		}
		else if ((tokens[i] == tok!"const" || tokens[i] == tok!"immutable" || tokens[i] == tok!"shared"
		|| tokens[i] == tok!"inout") && tokens[i + 1] == tok!"(")
		{
			writeToken(output, tokens[i]);
			i++;
			skipAndWrite!("(", ")")(output, tokens, i);
		}
		else
		{
			skipIdentifierChain(output, tokens, i, true);
			if (i < tokens.length && tokens[i] == tok!"!")
			{
				writeToken(output, tokens[i]);
				i++;
				if (i + 1 < tokens.length && tokens[i + 1] == tok!"(")
					skipAndWrite!("(", ")")(output, tokens, i);
				else if (tokens[i].type == tok!"identifier")
					skipIdentifierChain(output, tokens, i, true);
				else
				{
					writeToken(output, tokens[i]);
					i++;
				}
			}
		}

		skipWhitespace(output, tokens, i);

		// print out suffixes
		while (i < tokens.length && (tokens[i] == tok!"*" || tokens[i] == tok!"["))
		{
			if (tokens[i] == tok!"*")
			{
				writeToken(output, tokens[i]);
				i++;
			}
			else if (tokens[i] == tok!"[")
				skipAndWrite!("[", "]")(output, tokens, i);
		}
	}

	for (size_t i = 0; i < tokens.length; i++)
	{
		markerLoop: foreach (marker; markers)
		{
			with (SpecialMarkerType) final switch (marker.type)
			{
				case bodyEnd:
					if (tokens[i].index != marker.index)
						break;
					assert (tokens[i].type == tok!"}", format("%d %s", tokens[i].line, str(tokens[i].type)));
					writeToken(output, tokens[i]);
					i++;
					if (i < tokens.length && tokens[i] == tok!";")
						i++;
					markers = markers[1 .. $];
					break markerLoop;
				case functionAttributePrefix:
					if (tokens[i].index != marker.index)
						break;
					// skip over token to be moved
					i++;
					skipWhitespace(output, tokens, i, false);

					// skip over function return type
					writeType(output, tokens, i);
					skipWhitespace(output, tokens, i);

					// skip over function name
					skipIdentifierChain(output, tokens, i, true);
					skipWhitespace(output, tokens, i, false);

					// skip first paramters
					skipAndWrite!("(", ")")(output, tokens, i);

					immutable bookmark = i;
					skipWhitespace(output, tokens, i, false);

					// If there is a second set of parameters, go back to the bookmark
					// and print out the whitespace
					if (i < tokens.length && tokens[i] == tok!"(")
					{
						i = bookmark;
						skipWhitespace(output, tokens, i);
						skipAndWrite!("(", ")")(output, tokens, i);
						skipWhitespace(output, tokens, i, false);
					}
					else
						i = bookmark;

					// write out the attribute being moved
					output.write(" ", marker.functionAttribute);

					// if there was no whitespace, add it after the moved attribute
					if (i < tokens.length && tokens[i] != tok!"whitespace" && tokens[i] != tok!";")
						output.write(" ");

					markers = markers[1 .. $];
					break markerLoop;
				case cStyleArray:
					if (i != marker.index)
						break;
					formatter.sink = output.lockingTextWriter();
					foreach (node; retro(marker.nodes))
						formatter.format(node);
					formatter.sink = File.LockingTextWriter.init;
					skipWhitespace(output, tokens, i);
					writeToken(output, tokens[i]);
					i++;
					suffixLoop: while (i < tokens.length) switch (tokens[i].type)
					{
						case tok!"(":
							skipAndWrite!("(", ")")(output, tokens, i); break;
						case tok!"[":
							skip!("[", "]")(tokens, i); break;
						case tok!"*":
							i++; break;
						default: break suffixLoop;
					}
					markers = markers[1 .. $];
					break markerLoop;
			}
		}

		if (i >= tokens.length)
			break;

		switch (tokens[i].type)
		{
			case tok!"asm":
				skipAsmBlock(output, tokens, i);
				goto default;
			case tok!"catch":
				if (!dip65)
					goto default;
				size_t j = i + 1;
				while (j < tokens.length && (tokens[j] == tok!"whitespace" || tokens[j] == tok!"comment"))
					j++;
				if (j < tokens.length && tokens[j].type != tok!"(")
				{
					output.write("catch (Throwable)");
					break;
				}
				else
					goto default;
			case tok!"deprecated":
				if (dip64)
					output.write("@");
				output.writeToken(tokens[i]);
				i++;
				if (i < tokens.length && tokens[i] == tok!"(")
					skipAndWrite!("(", ")")(output, tokens, i);
				if (i < tokens.length)
					goto default;
				else
					break;
			case tok!"stringLiteral":
				immutable size_t stringBookmark = i;
				while (tokens[i] == tok!"stringLiteral")
				{
					i++;
					skipWhitespace(output, tokens, i, false);
				}
				immutable bool parensNeeded = stringBookmark + 1 != i && tokens[i] == tok!".";
				i = stringBookmark;
				if (parensNeeded)
					output.write("(");
				output.writeToken(tokens[i]);
				i++;
				skipWhitespace(output, tokens, i);
				while (tokens[i] == tok!"stringLiteral")
				{
					output.write("~ ");
					output.writeToken(tokens[i]);
					i++;
					skipWhitespace(output, tokens, i);
				}
				if (parensNeeded)
					output.write(")");
				if (i < tokens.length)
					goto default;
				else
					break;
			case tok!"override":
			case tok!"final":
			case tok!"abstract":
			case tok!"align":
			case tok!"pure":
			case tok!"nothrow":
				if (!dip64)
					goto default;
				output.write("@");
				output.write(str(tokens[i].type));
				break;
			case tok!"alias":
				bool multipleAliases = false;
				bool oldStyle = true;
				output.writeToken(tokens[i]); // alias
				i++;
				size_t j = i + 1;

				int depth;
				loop: while (j < tokens.length) switch (tokens[j].type)
				{
					case tok!"(":
						depth++;
						j++;
						break;
					case tok!")":
						depth--;
						if (depth < 0)
						{
							oldStyle = false;
							break loop;
						}
						j++;
						break;
					case tok!"=":
					case tok!"this":
						j++;
						oldStyle = false;
						break;
					case tok!",":
						j++;
						if (depth == 0)
							multipleAliases = true;
						break;
					case tok!";":
						break loop;
					default:
						j++;
						break;
				}

				if (!oldStyle) foreach (k; i .. j + 1)
				{
					output.writeToken(tokens[k]);
					i = k;
				}
				else
				{
					skipWhitespace(output, tokens, i);

					size_t beforeStart = i;
					size_t beforeEnd = beforeStart;

					loop2: while (beforeEnd < tokens.length) switch (tokens[beforeEnd].type)
					{
						case tok!"bool":
						case tok!"byte":
						case tok!"ubyte":
						case tok!"short":
						case tok!"ushort":
						case tok!"int":
						case tok!"uint":
						case tok!"long":
						case tok!"ulong":
						case tok!"char":
						case tok!"wchar":
						case tok!"dchar":
						case tok!"float":
						case tok!"double":
						case tok!"real":
						case tok!"ifloat":
						case tok!"idouble":
						case tok!"ireal":
						case tok!"cfloat":
						case tok!"cdouble":
						case tok!"creal":
						case tok!"void":
							beforeEnd++;
							break loop2;
						case tok!".":
							beforeEnd++;
							goto case;
						case tok!"identifier":
							skipIdentifierChain(output, tokens, beforeEnd);
							break loop2;
						case tok!"typeof":
							beforeEnd++;
							skip!("(", ")")(tokens, beforeEnd);
							skipWhitespace(output, tokens, beforeEnd, false);
							if (tokens[beforeEnd] == tok!".")
								skipIdentifierChain(output, tokens, beforeEnd);
							break loop2;
						case tok!"@":
							beforeEnd++;
							if (tokens[beforeEnd] == tok!"identifier")
								beforeEnd++;
							if (tokens[beforeEnd] == tok!"(")
								skip!("(", ")")(tokens, beforeEnd);
							skipWhitespace(output, tokens, beforeEnd, false);
							break;
						case tok!"static":
						case tok!"const":
						case tok!"immutable":
						case tok!"inout":
						case tok!"shared":
						case tok!"extern":
						case tok!"nothrow":
						case tok!"pure":
						case tok!"__vector":
							beforeEnd++;
							skipWhitespace(output, tokens, beforeEnd, false);
							if (tokens[beforeEnd] == tok!"(")
								skip!("(", ")")(tokens, beforeEnd);
							if (beforeEnd >= tokens.length)
								break loop2;
							size_t k = beforeEnd;
							skipWhitespace(output, tokens, k, false);
							if (k + 1 < tokens.length && tokens[k + 1].type == tok!";")
								break loop2;
							else
								beforeEnd = k;
							break;
						default:
							break loop2;
					}

					i = beforeEnd;

					skipWhitespace(output, tokens, i, false);

					if (tokens[i] == tok!"*" || tokens[i] == tok!"["
					|| tokens[i] == tok!"function" || tokens[i] == tok!"delegate")
					{
						beforeEnd = i;
					}

					loop3: while (beforeEnd < tokens.length) switch (tokens[beforeEnd].type)
					{
						case tok!"*":
							beforeEnd++;
							size_t m = beforeEnd;
							skipWhitespace(output, tokens, m, false);
							if (m < tokens.length && (tokens[m] == tok!"*"
							|| tokens[m] == tok!"[" || tokens[m] == tok!"function"
							|| tokens[m] == tok!"delegate"))
							{
								beforeEnd = m;
							}
							break;
						case tok!"[":
							skip!("[", "]")(tokens, beforeEnd);
							size_t m = beforeEnd;
							skipWhitespace(output, tokens, m, false);
							if (m < tokens.length && (tokens[m] == tok!"*"
							|| tokens[m] == tok!"[" || tokens[m] == tok!"function"
							|| tokens[m] == tok!"delegate"))
							{
								beforeEnd = m;
							}
							break;
						case tok!"function":
						case tok!"delegate":
							beforeEnd++;
							skipWhitespace(output, tokens, beforeEnd, false);
							skip!("(", ")")(tokens, beforeEnd);
							size_t l = beforeEnd;
							skipWhitespace(output, tokens, l, false);
							loop4: while (l < tokens.length) switch (tokens[l].type)
							{
								case tok!"const":
								case tok!"nothrow":
								case tok!"pure":
								case tok!"immutable":
								case tok!"inout":
								case tok!"shared":
									beforeEnd = l + 1;
									l = beforeEnd;
									skipWhitespace(output, tokens, l, false);
									if (l < tokens.length && tokens[l].type == tok!"identifier")
									{
										beforeEnd = l - 1;
										break loop4;
									}
									break;
								case tok!"@":
									beforeEnd = l + 1;
									skipWhitespace(output, tokens, beforeEnd, false);
									if (tokens[beforeEnd] == tok!"(")
										skip!("(", ")")(tokens, beforeEnd);
									else
									{
										beforeEnd++; // identifier
										skipWhitespace(output, tokens, beforeEnd, false);
										if (tokens[beforeEnd] == tok!"(")
											skip!("(", ")")(tokens, beforeEnd);
									}
									l = beforeEnd;
									skipWhitespace(output, tokens, l, false);
									if (l < tokens.length && tokens[l].type == tok!"identifier")
									{
										beforeEnd = l - 1;
										break loop4;
									}
									break;
								default:
									break loop4;
							}
							break;
						default:
							break loop3;
					}

					i = beforeEnd;
					skipWhitespace(output, tokens, i, false);

					output.writeToken(tokens[i]);
					output.write(" = ");
					foreach (l; beforeStart .. beforeEnd)
						output.writeToken(tokens[l]);

					if (multipleAliases)
					{
						i++;
						skipWhitespace(output, tokens, i, false);
						while (tokens[i] == tok!",")
						{
							i++; // ,
							output.write(", ");
							skipWhitespace(output, tokens, i, false);
							output.writeToken(tokens[i]);
							output.write(" = ");
							foreach (l; beforeStart .. beforeEnd)
								output.writeToken(tokens[l]);
						}
					}
				}
				break;
			case tok!"identifier":
				if (tokens[i].text == "body")
						(dip1003 && tokens.isBodyKw(i)) ? output.write("do") : output.write("body");
				else
					goto default;
				break;
			default:
				output.writeToken(tokens[i]);
				break;
		}
	}
}

/**
 * Converts the marker index from a byte index into the source code to an index
 * into the tokens array.
 */
void relocateMarkers(SpecialMarker[] markers, const(Token)[] tokens) pure nothrow @nogc
{
	foreach (ref marker; markers)
	{
		if (marker.type != SpecialMarkerType.cStyleArray)
			continue;

		size_t index = 0;
		while (tokens[index].index != marker.index)
			index++;

		marker.index = index - 1;
	}
}

/**
 * Returns true if `body` is a keyword and false if it's an identifier.
 */
bool isBodyKw(const(Token)[] tokens, size_t index)
{
	assert(index);
	index -= 1;

	while (index--) switch (tokens[index].type)
	{
		// `in {} body {}`
		case tok!"}":
			return true;
		case tok!"comment":
			continue;
		// `void foo () return {}` or `return body;`
		case tok!"return":
			continue;
		// `void foo () @safe pure body {}`
		case tok!")":
		case tok!"const":
		case tok!"immutable":
		case tok!"inout":
		case tok!"shared":
		case tok!"@":
		case tok!"pure":
		case tok!"nothrow":
		case tok!"scope":
			return true;
		default:
			return false;
	}

	return false;
}
