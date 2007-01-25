{-# OPTIONS -cpp -fglasgow-exts #-}

{-| In the concrete syntax the clauses of a function are not grouped together.
    Neither is the fixity declaration attached to its corresponding definition.
    This module defines the function to do this grouping and associate fixities
    with declarations rather than having them floating freely.

Thoughts:

What are the options?

- All in one go

    > magic :: [Definition args] -> [BetterDefinition args]

  For this we also need a new kind of expression (for which local definitions
  are the better kind of definition). This would be done by parameterising the
  expression type.

  Alternatively we don't distinguish between Definition and BetterDefinition
  and just state the invariant. This doesn't follow the current design of
  having the type checker ensure these invariants.

- The view approach

    > data Definitions (abstract)
    > 
    > rawView :: Definitions -> [Definition]
    > magic :: Definitions -> [BetterDefinition]

  The advantage here is that we can let the kind of local definitions in
  expressions be the abstract Definitions, so we only need one kind of
  expression.

  The disadvantage would be that we have to call the view all the time. All the
  time would be... when translating to abstract syntax and rotating infix
  stuff. Infix rotation has to be done after scope analysis, and since there
  won't be any parenthesis in the abstract syntax, it's probably easiest to do
  it at the same time.

  Actually, since the abstract thing definition would just be the raw
  definition we could skip the view business and write the magic function that
  just transforms the top-level list of definitions.


  Hm... at the moment, left hand sides are parsed as expressions. The idea is
  that when we know the fixities of the operators we can turn this expression
  into a proper left hand side. The problem with this is that we have to sort
  out the fixities before even knowing what name a particular clause defines.
  The current idea, to first group the definitions and then rotate infix
  applications, won't work. The solution is to make sure that we always know
  which name is being defined.

  Ok, representation of left hand sides are not expressions anymore and we
  always now which name a left hand side defines.

-}
module Syntax.Concrete.Definitions
    ( NiceDeclaration(..)
    , NiceDefinition(..)
    , NiceConstructor, NiceTypeSignature
    , Clause(..)
    , DeclarationException(..)
    , niceDeclarations
    ) where

import Control.Exception

import Data.Generics (Data, Typeable)
import qualified Data.Map as Map

import Syntax.Concrete
import Syntax.Common
import Syntax.Position
import Syntax.Fixity
import Syntax.Concrete.Pretty ()    -- need Show instance for Declaration

#include "../../undefined.h"

{--------------------------------------------------------------------------
    Types
 --------------------------------------------------------------------------}

{-| The nice declarations. No fixity declarations and function definitions are
    contained in a single constructor instead of spread out between type
    signatures and clauses. The @private@, @postulate@, and @abstract@
    modifiers have been distributed to the individual declarations.
-}
data NiceDeclaration
	= Axiom Range Fixity Access IsAbstract Name Expr
	| PrimitiveFunction Range Fixity Access IsAbstract Name Expr
	| NiceDef Range [Declaration] [NiceTypeSignature] [NiceDefinition]
	    -- ^ A bunch of mutually recursive functions\/datatypes.
	    --   The last two lists have the same length. The first list is the
	    --   concrete declarations these definitions came from.
	| NiceModule Range Access IsAbstract QName Telescope [Declaration]
	| NiceModuleMacro Range Access IsAbstract Name Telescope Expr OpenShortHand ImportDirective
	| NiceOpen Range QName ImportDirective
	| NiceImport Range QName (Maybe Name) OpenShortHand ImportDirective
	| NicePragma Range Pragma
    deriving (Show, Typeable, Data)

-- | A definition without its type signature.
data NiceDefinition
	= FunDef  Range [Declaration] Fixity Access IsAbstract Name [Clause]
	| DataDef Range Fixity Access IsAbstract Name [LamBinding] [NiceConstructor]
    deriving (Show, Typeable, Data)

-- | Only 'Axiom's.
type NiceConstructor = NiceDeclaration

-- | Only 'Axiom's.
type NiceTypeSignature	= NiceDeclaration

-- | One clause in a function definition. There is no guarantee that the 'LHS'
--   actually declares the 'Name'. We will have to check that later.
data Clause = Clause Name LHS RHS WhereClause
    deriving (Show, Typeable, Data)

-- | The exception type.
data DeclarationException
	= MultipleFixityDecls [(Name, [Fixity])]
	| MissingDefinition Name
	| MissingTypeSignature LHS
	| NotAllowedInMutual NiceDeclaration
    deriving (Typeable, Show)

instance HasRange DeclarationException where
    getRange (MultipleFixityDecls xs) = getRange (fst $ head xs)
    getRange (MissingDefinition x)    = getRange x
    getRange (MissingTypeSignature x) = getRange x
    getRange (NotAllowedInMutual x)   = getRange x

instance HasRange NiceDeclaration where
    getRange (Axiom r _ _ _ _ _)	       = r
    getRange (NiceDef r _ _ _)		       = r
    getRange (NiceModule r _ _ _ _ _)	       = r
    getRange (NiceModuleMacro r _ _ _ _ _ _ _) = r
    getRange (NiceOpen r _ _)		       = r
    getRange (NiceImport r _ _ _ _)	       = r
    getRange (NicePragma r _)		       = r
    getRange (PrimitiveFunction r _ _ _ _ _)   = r

{--------------------------------------------------------------------------
    The niceifier
 --------------------------------------------------------------------------}

{-| How to fail? We need to give a nice error message. Intuitively it should be
    a parse error. Put it in the parse monad?

    It would be nice to have a general mechanism. Lots of things fail
    (parsing, type checking, translation...), how to handle this uniformly?
    Control.Monad.Error? What would the error object be?

    Niklas suggested using exceptions. Can be thrown by a pure function but
    have to be caught in IO. The advantage is that things whose only side
    effect is the possibility of failure don't need a monad. If one uses
    dynamic exceptions each function can define it's own exception type in a
    modular way.

    The disadvantage is that the type won't reflect the fact that the function
    might throw an exception.

    Let's go with that.

    TODO: check that every fixity declaration has a corresponding definition.
    How to do this?

    Update the fixity map with usage counters? It would need to be a state
    monad rather than a reader monad in that case.
-}
niceDeclarations :: [Declaration] -> [NiceDeclaration]
niceDeclarations ds = nice (fixities ds) ds
    where

	-- If no fixity is given we return the default fixity.
	fixity :: Name -> Map.Map Name Fixity -> Fixity
	fixity = Map.findWithDefault defaultFixity

	-- We forget all fixities in recursive calls. This is because
	-- fixity declarations have to appear at the same level as the
	-- declaration.
	fmapNice x = fmap niceDeclarations x

	nice _ []	 = []
	nice fixs (d:ds) =
	    case d of
		TypeSig x t ->
		    -- After a type signature there should follow a bunch of
		    -- clauses.
		    case span (isFunClauseOf x) ds of
			([], _)	    -> throwDyn $ MissingDefinition x
			(ds0,ds1)   -> mkFunDef fixs x (Just t) ds0
					: nice fixs ds1

		cl@(FunClause lhs _ _) -> case noSingletonRawAppP lhs of
		    IdentP (QName x)	-> mkFunDef fixs x Nothing [cl] : nice fixs ds
		    _			-> throwDyn $ MissingTypeSignature lhs

		_   -> nds ++ nice fixs ds
		    where
			nds = case d of
			    Data r x tel t cs   ->
				[ NiceDef r [d]
					    [ Axiom (fuseRange x t) f PublicAccess ConcreteDef
						    x (Pi tel t)
					    ]
					    [ DataDef (getRange cs) f PublicAccess ConcreteDef x
						      (concatMap binding tel)
						      (niceAxioms fixs cs)
					    ]
				]
				where
				    f = fixity x fixs
				    binding (TypedBindings _ h bs) =
					concatMap (bind h) bs
				    bind h (TBind _ xs _) =
					map (DomainFree h) xs
				    bind h (TNoBind e) =
					[ DomainFree h $ noName (getRange e) ]

			    Mutual r ds ->
				[ mkMutual r [d] $
				    nice (fixities ds `plusFixities` fixs) ds
				]

			    Abstract r ds ->
				map mkAbstract
				$ nice (fixities ds `plusFixities` fixs) ds

			    Private _ ds ->
				map mkPrivate
				$ nice (fixities ds `plusFixities` fixs) ds

			    Postulate _ ds -> niceAxioms fixs ds

			    Primitive _ ds -> map toPrim $ niceAxioms fixs ds

			    Module r x tel ds	->
				[ NiceModule r PublicAccess ConcreteDef x tel ds ]

			    ModuleMacro r x tel e op is ->
				[ NiceModuleMacro r PublicAccess ConcreteDef x tel e op is ]

			    Infix _ _		-> []
			    Open r x is		-> [NiceOpen r x is]
			    Import r x as op is	-> [NiceImport r x as op is]

			    Pragma p		-> [NicePragma (getRange p) p]

			    FunClause _ _ _	-> __IMPOSSIBLE__
			    TypeSig _ _		-> __IMPOSSIBLE__


	-- Translate axioms
	niceAxioms :: Map.Map Name Fixity -> [TypeSignature] -> [NiceDeclaration]
	niceAxioms fixs ds = nice ds
	    where
		nice [] = []
		nice (d@(TypeSig x t) : ds) =
		    Axiom (getRange d) (fixity x fixs) PublicAccess ConcreteDef x t
		    : nice ds
		nice _ = __IMPOSSIBLE__

	toPrim :: NiceDeclaration -> NiceDeclaration
	toPrim (Axiom r f a c x t) = PrimitiveFunction r f a c x t
	toPrim _		   = __IMPOSSIBLE__

	-- Create a function definition.
	mkFunDef fixs x mt ds0 =
	    NiceDef (fuseRange x ds0)
		    (TypeSig x t : ds0)
		    [ Axiom (fuseRange x t) f PublicAccess ConcreteDef x t ]
		    [ FunDef (getRange ds0) ds0 f PublicAccess ConcreteDef x
			     (map (mkClause x) ds0)
		    ]
	    where
		f  = fixity x fixs
		t = case mt of
			Just t	-> t
			Nothing	-> Underscore (getRange x) Nothing


	-- Turn a function clause into a nice function clause.
	mkClause x (FunClause lhs rhs wh) = Clause x lhs rhs wh
	mkClause _ _ = __IMPOSSIBLE__

	noSingletonRawAppP (RawAppP _ [p]) = noSingletonRawAppP p
	noSingletonRawAppP p		   = p

	isFunClauseOf x (FunClause lhs _ _) = case noSingletonRawAppP lhs of
	    IdentP (QName q)	-> x == q
	    _			-> True
		-- more complicated lhss must come with type signatures, so we just assume
		-- it's part of the current definition
	isFunClauseOf _ _ = False

	-- Make a mutual declaration
	mkMutual :: Range -> [Declaration] -> [NiceDeclaration] -> NiceDeclaration
	mkMutual r cs ds = setConcrete cs $ foldr smash (NiceDef r [] [] []) ds
	    where
		setConcrete cs (NiceDef r _ ts ds)  = NiceDef r cs ts ds
		setConcrete cs d		    = throwDyn $ NotAllowedInMutual d

		smash (NiceDef r0 _ ts0 ds0) (NiceDef r1 _ ts1 ds1) =
		    NiceDef (fuseRange r0 r1) [] (ts0 ++ ts1) (ds0 ++ ds1)
		smash (NiceDef _ _ _ _) d = throwDyn $ NotAllowedInMutual d
		smash d _		  = throwDyn $ NotAllowedInMutual d

	-- Make a declaration abstract
	mkAbstract d =
	    case d of
		Axiom r f a _ x e		    -> Axiom r f a AbstractDef x e
		PrimitiveFunction r f a _ x e	    -> PrimitiveFunction r f a AbstractDef x e
		NiceDef r cs ts ds		    -> NiceDef r cs (map mkAbstract ts)
								 (map mkAbstractDef ds)
		NiceModule r a _ x tel ds	    -> NiceModule r a AbstractDef x tel [ Abstract (getRange ds) ds ]
		NiceModuleMacro r a _ x tel e op is -> NiceModuleMacro r a AbstractDef x tel e op is
		NicePragma _ _			    -> d
		NiceOpen _ _ _			    -> d
		NiceImport _ _ _ _ _		    -> d

	mkAbstractDef d =
	    case d of
		FunDef r ds f a _ x cs	-> FunDef r ds f a AbstractDef x
						  (map mkAbstractClause cs)
		DataDef r f a _ x ps cs	-> DataDef r f a AbstractDef x ps $ map mkAbstract cs

	mkAbstractClause c@(Clause _ _ _ []) = c
	mkAbstractClause (Clause x lhs rhs ds) =
	    Clause x lhs rhs [Abstract (getRange ds) ds]

	-- Make a declaration private
	mkPrivate d =
	    case d of
		Axiom r f _ a x e		    -> Axiom r f PrivateAccess a x e
		PrimitiveFunction r f _ a x e	    -> PrimitiveFunction r f PrivateAccess a x e
		NiceDef r cs ts ds		    -> NiceDef r cs (map mkPrivate ts)
								    (map mkPrivateDef ds)
		NiceModule r _ a x tel ds	    -> NiceModule r PrivateAccess a x tel ds
		NiceModuleMacro r _ a x tel e op is -> NiceModuleMacro r PrivateAccess a x tel e op is
		NicePragma _ _			    -> d
		NiceOpen _ _ _			    -> d
		NiceImport _ _ _ _ _		    -> d

	mkPrivateDef d =
	    case d of
		FunDef r ds f _ a x cs	-> FunDef r ds f PrivateAccess a x
						  (map mkPrivateClause cs)
		DataDef r f _ a x ps cs	-> DataDef r f PrivateAccess a x ps cs

	mkPrivateClause c@(Clause _ _ _ []) = c
	mkPrivateClause (Clause x lhs rhs ds) =
	    Clause x lhs rhs [Private (getRange ds) ds]

-- | Add more fixities. Throw an exception for multiple fixity declarations.
plusFixities :: Map.Map Name Fixity -> Map.Map Name Fixity -> Map.Map Name Fixity
plusFixities m1 m2
    | Map.null isect	= Map.union m1 m2
    | otherwise		=
	throwDyn $ MultipleFixityDecls $ map decls (Map.keys isect)
    where
	isect	= Map.intersection m1 m2
	decls x = (x, map (Map.findWithDefault __IMPOSSIBLE__ x) [m1,m2])
				-- cpp doesn't know about primes

-- | Get the fixities from the current block. Doesn't go inside /any/ blocks.
--   The reason for this is that fixity declarations have to appear at the same
--   level (or possibly outside an abstract or mutual block) as its target
--   declaration.
fixities :: [Declaration] -> Map.Map Name Fixity
fixities (d:ds) =
    case d of
	Infix f xs  -> Map.fromList [ (x,f) | x <- xs ]
			`plusFixities` fixities ds
	_	    -> fixities ds
fixities [] = Map.empty

