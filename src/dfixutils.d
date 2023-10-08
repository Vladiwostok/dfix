module dfixutils;

import std.stdio : File;
import dparse.lexer : Token;

ubyte[] readFile(string fileName)
{
	import std.array : uninitializedArray;

	File file = File(fileName, "rb");
	ubyte[] fileContent = uninitializedArray!(ubyte[])(cast(size_t) file.size);
	file.rawRead(fileContent);
	file.close();

	return fileContent;
}

/**
 * Writes a token to the output file.
 */
void writeToken(File output, ref const(Token) token)
{
	import dparse.lexer : str;
	output.write(token.text is null ? str(token.type) : token.text);
}

void writeType(T)(File output, T tokens, ref size_t i)
{
	import dparse.lexer, skiputils;

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

/**
 * Prints help message
 */
void printHelp()
{
	import std.stdio : stdout;

	stdout.writeln(`
Dfix automatically upgrades D source code to comply with new language changes.
Files are modified in place, so have backup copies ready or use a source
control system.

Usage:

    dfix [Options] FILES DIRECTORIES

Options:

    --dip64
        Rewrites attributes to be compliant with DIP64. This defaults to
        "false". Do not use this feature if you want your code to compile.
		It exists as a proof-of-concept for enabling DIP64.
    --dip65
        Rewrites catch blocks to be compliant with DIP65. This defaults to
        "true". Use --dip65=false to disable this fix.
    --dip1003
        Rewrites body blocks to be compliant with DIP1003. This defaults to
        "true". Use --dip1003=false to disable this fix.
    --help -h
        Prints this help message
`);
}

/**
 * Dummy message output function for the lexer/parser
 */
void reportErrors(string fileName, size_t lineNumber, size_t columnNumber, string message, bool isError)
{
	import std.stdio : stderr;

	if (!isError)
		return;

	stderr.writefln("%s(%d:%d)[error]: %s", fileName, lineNumber, columnNumber, message);
}
