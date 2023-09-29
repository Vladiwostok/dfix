module dfixvisitor;

import markers;
import dparse.ast;
import dparse.lexer;

/**
 * Scans a module's parsed AST and looks for C-style array variables and
 * parameters, storing the locations in the markers array.
 */
class DFixVisitor : ASTVisitor
{
	alias visit = ASTVisitor.visit;

	/// Parts of the source file identified as needing a rewrite
	SpecialMarker[] markers;

	// C-style arrays variables
	override void visit(const VariableDeclaration varDec)
	{
		if (varDec.declarators.length == 0)
			return;

		markers ~= SpecialMarker(SpecialMarkerType.cStyleArray,
		varDec.declarators[0].name.index, varDec.declarators[0].cstyle);
	}

	// C-style array parameters
	override void visit(const Parameter param)
	{
		if (param.cstyle.length > 0)
			markers ~= SpecialMarker(SpecialMarkerType.cStyleArray, param.name.index, param.cstyle);

		param.accept(this);
	}

	// interface, union, class, struct body closing braces
	override void visit(const StructBody structBody)
	{
		structBody.accept(this);
		markers ~= SpecialMarker(SpecialMarkerType.bodyEnd, structBody.endLocation);
	}

	// enum body closing braces
	override void visit(const EnumBody enumBody)
	{
		enumBody.accept(this);

		// skip over enums whose body is a single semicolon
		if (enumBody.endLocation == 0 && enumBody.startLocation == 0)
			return;

		markers ~= SpecialMarker(SpecialMarkerType.bodyEnd, enumBody.endLocation);
	}

	// Confusing placement of function attributes
	override void visit(const Declaration dec)
	{
		if (dec.functionDeclaration is null)
			goto end;

		if (dec.attributes.length == 0)
			goto end;

		foreach (attr; dec.attributes)
		{
			if (attr.attribute == tok!"")
				continue;

			if (attr.attribute == tok!"const" || attr.attribute == tok!"inout" || attr.attribute == tok!"immutable")
			{
				markers ~= SpecialMarker(SpecialMarkerType.functionAttributePrefix,
				attr.attribute.index, null, str(attr.attribute.type));
			}
		}

		end:
			dec.accept(this);
	}
}
