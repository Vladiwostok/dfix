module skiputils;

import std.stdio;
import dparse.lexer;
import dfixutils;

void skipAndWrite(alias Open, alias Close)(File output, const(Token)[] tokens, ref size_t index)
{
	int depth = 1;
	writeToken(output, tokens[index]);
	index++;

	while (index < tokens.length && depth > 0) switch (tokens[index].type)
	{
		case tok!Open:
			depth++;
			writeToken(output, tokens[index]);
			index++;
			break;
		case tok!Close:
			depth--;
			writeToken(output, tokens[index]);
			index++;
			break;
		default:
			writeToken(output, tokens[index]);
			index++;
			break;
	}
}

/**
 * Skips balanced parens, braces, or brackets. index will be incremented to
 * index tokens just after the balanced closing token.
 */
void skip(alias Open, alias Close)(const(Token)[] tokens, ref size_t index)
{
	int depth = 1;
	index++;

	while (index < tokens.length && depth > 0) switch (tokens[index].type)
	{
		case tok!Open:
			depth++;
			index++;
			break;
		case tok!Close:
			depth--;
			index++;
			break;
		default:
			index++;
			break;
	}
}

/**
 * Skips whitespace tokens, incrementing index until it indexes tokens at a
 * non-whitespace token.
 */
void skipWhitespace(File output, const(Token)[] tokens, ref size_t index, bool print = true)
{
	while (index < tokens.length && (tokens[index] == tok!"whitespace" || tokens[index] == tok!"comment"))
	{
		if (print)
			output.writeToken(tokens[index]);

		index++;
	}
}

/**
 * Advances index until it indexs the token just after an identifier or template
 * chain.
 */
void skipIdentifierChain(File output, const(Token)[] tokens, ref size_t index, bool print = false)
{
	while (index < tokens.length) switch (tokens[index].type)
	{
		case tok!".":
			if (print)
				writeToken(output, tokens[index]);
			index++;
			skipWhitespace(output, tokens, index, false);
			break;
		case tok!"identifier":
			if (print)
				writeToken(output, tokens[index]);
			index++;
			size_t i = index;
			skipWhitespace(output, tokens, i, false);
			if (tokens[i] == tok!"!")
			{
				i++;
				if (print)
					writeToken(output, tokens[index]);
				index++;
				skipWhitespace(output, tokens, i, false);
				if (tokens[i] == tok!"(")
				{
					if (print)
						skipAndWrite!("(", ")")(output, tokens, i);
					else
						skip!("(", ")")(tokens, i);
					index = i;
				}
				else
				{
					i++;
					if (print)
						writeToken(output, tokens[index]);
					index++;
				}
			}
			if (tokens[i] != tok!".")
				return;

			break;
		case tok!"whitespace":
			index++;
			break;
		default:
			return;
	}
}

/**
 * Skips over an attribute
 */
void skipAttribute(File output, const(Token)[] tokens, ref size_t i)
{
	switch (tokens[i].type)
	{
		case tok!"@":
			output.writeToken(tokens[i]);
			i++; // @
			skipWhitespace(output, tokens, i, true);
			switch (tokens[i].type)
			{
				case tok!"identifier":
					output.writeToken(tokens[i]);
					i++; // identifier
					skipWhitespace(output, tokens, i, true);
					if (tokens[i].type == tok!"(")
						goto case tok!"(";
					break;
				case tok!"(":
					int depth = 1;
					output.writeToken(tokens[i]);
					i++;
					while (i < tokens.length && depth > 0) switch (tokens[i].type)
					{
						case tok!"(":
							depth++; output.writeToken(tokens[i]); i++; break;
						case tok!")":
							depth--; output.writeToken(tokens[i]); i++; break;
						default:               output.writeToken(tokens[i]); i++; break;
					}
					break;
				default:
					break;
			}
			break;
		case tok!"nothrow":
		case tok!"pure":
			output.writeToken(tokens[i]);
			i++;
			break;
		default:
			break;
	}
}

/**
 * Skips over (and prints) an asm block
 */
void skipAsmBlock(File output, const(Token)[] tokens, ref size_t i)
{
	import std.exception : enforce;

	output.write("asm");
	i++; // asm
	skipWhitespace(output, tokens, i);

	loop: while (true) switch (tokens[i].type)
	{
		case tok!"@":
		case tok!"nothrow":
		case tok!"pure":
			skipAttribute(output, tokens, i);
			skipWhitespace(output, tokens, i);
			break;
		case tok!"{":
			break loop;
		default:
			break loop;
	}

	enforce(tokens[i].type == tok!"{");
	output.write("{");

	i++; // {
	int depth = 1;

	while (depth > 0 && i < tokens.length) switch (tokens[i].type)
	{
		case tok!"{":
			depth++; goto default;
		case tok!"}":
			depth--; goto default;
		default:
			writeToken(output, tokens[i]);
			i++;
			break;
	}
}
