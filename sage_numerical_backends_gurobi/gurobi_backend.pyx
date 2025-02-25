"""
Gurobi Backend

TESTS:

Bug from :trac:`12833`::

    sage: g = DiGraph('IESK@XgAbCgH??KG??')
    sage: g.feedback_edge_set(value_only = True, constraint_generation = False)
    7
    sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
    sage: g.feedback_edge_set(value_only = True, constraint_generation = False, solver=GurobiBackend)
    7

Methods
-------
"""

#*****************************************************************************
#       Copyright (C) 2010-2014 Nathann Cohen <nathann.cohen@gmail.com>
#       Copyright (C) 2012 John Perry <john.perry@usm.edu>
#       Copyright (C) 2016-2019 Matthias Koeppe <mkoeppe@math.ucdavis.edu>
#       Copyright (C) 2017 Jori Mäntysalo <jori.mantysalo@uta.fi>
#       Copyright (C) 2018 Erik M. Bray <erik.bray@lri.fr>
#       Copyright (C( 2012-2019 Jeroen Demeyer <jeroen.k.demeyer@gmail.com>
#       Copyright (C) 2015-2019 David Coudert <david.coudert@inria.fr>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  http://www.gnu.org/licenses/
#*****************************************************************************

from cysignals.memory cimport sig_malloc, sig_free

IF HAVE_SAGE_CPYTHON_STRING:
    from sage.cpython.string cimport char_to_str, str_to_bytes
    from sage.cpython.string import FS_ENCODING
from sage.numerical.mip import MIPSolverException

cdef class GurobiBackend(GenericBackend):

    """
    MIP Backend that uses the Gurobi solver.

    TESTS:

    General backend testsuite::

        sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
        sage: p = MixedIntegerLinearProgram(solver=GurobiBackend)
        sage: TestSuite(p.get_backend()).run(skip="_test_pickling")

    Ticket :trac:`28206` is fixed::

        sage: G = graphs.PetersenGraph()
        sage: G.maximum_average_degree(solver=GurobiBackend)
        3
    """

    def __init__(self, maximization = True):
        """
        Constructor

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = MixedIntegerLinearProgram(solver=GurobiBackend)
        """
        cdef int error

        # Initializing the master Environment. This one is kept to be
        # deallocated on __dealloc__
        error = GRBemptyenv(&self.env_master)
        if self.env_master == NULL:
            raise RuntimeError("Could not initialize Gurobi environment")
        check(self.env_master, error)
        error = GRBsetintparam(self.env_master, "OutputFlag", 0)
        check(self.env_master, error)
        error = GRBstartenv(self.env_master)
        check(self.env_master, error)

        # Initializing the model
        error = GRBnewmodel(self.env_master, &self.model, NULL, 0, NULL, NULL, NULL, NULL, NULL)

        self.env = GRBgetenv(self.model)

        if error:
            raise RuntimeError("Could not initialize Gurobi model")

        if maximization:
            error = GRBsetintattr(self.model, "ModelSense", -1)
        else:
            error = GRBsetintattr(self.model, "ModelSense", +1)

        check(self.env, error)

        self.set_sense(1 if maximization else -1)

        self.set_verbosity(0)
        self.obj_constant_term = 0.0

    cpdef int add_variable(self, lower_bound=0.0, upper_bound=None, binary=False, continuous=False, integer=False, obj=0.0, name=None, coefficients=None) except -1:
        ## coefficients is an extension in this backend,
        ## and a proposed addition to the interface, to unify this with add_col.
        """
        Add a variable.

        This amounts to adding a new column to the matrix. By default,
        the variable is both positive, real and the coefficient in the
        objective function is 0.0.

        INPUT:

        - ``lower_bound`` - the lower bound of the variable (default: 0)

        - ``upper_bound`` - the upper bound of the variable (default: ``None``)

        - ``binary`` - ``True`` if the variable is binary (default: ``False``).

        - ``continuous`` - ``True`` if the variable is binary (default: ``True``).

        - ``integer`` - ``True`` if the variable is binary (default: ``False``).

        - ``obj`` - (optional) coefficient of this variable in the objective function (default: 0.0)

        - ``name`` - an optional name for the newly added variable (default: ``None``).

        OUTPUT: The index of the newly created variable

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.ncols()
            0
            sage: p.add_variable()
            0
            sage: p.ncols()
            1
            sage: p.add_variable(binary=True)
            1
            sage: p.add_variable(lower_bound=-2.0, integer=True)
            2
            sage: p.add_variable(continuous=True, integer=True)
            Traceback (most recent call last):
            ...
            ValueError: ...
            sage: p.add_variable(name='x',obj=1.0)
            3
            sage: p.col_name(3)
            'x'
            sage: p.objective_coefficient(3)
            1.0
        """
        # Checking the input
        cdef char vtype = int(bool(binary)) + int(bool(continuous)) + int(bool(integer))
        if  vtype == 0:
            continuous = True
        elif vtype != 1:
            raise ValueError("Exactly one parameter of 'binary', 'integer' and 'continuous' must be 'True'.")

        cdef int error

        if binary:
            vtype = GRB_BINARY
        elif continuous:
            vtype = GRB_CONTINUOUS
        elif integer:
            vtype = GRB_INTEGER

        cdef char * c_name = ""

        if name is None:
            name = b"x_" + bytes(self.ncols())
        else:
            name = str_to_bytes(name)
        c_name = name

        if upper_bound is None:
            upper_bound = GRB_INFINITY
        if lower_bound is None:
            lower_bound = -GRB_INFINITY

        nonzeros = 0
        cdef int * c_indices = NULL
        cdef double * c_coeff = NULL

        if coefficients is not None:

            coefficients = list(coefficients)
            nonzeros = len(coefficients)
            c_indices = <int *> sig_malloc(nonzeros * sizeof(int))
            c_coeff = <double *> sig_malloc(nonzeros * sizeof(double))

            for i, (index, coeff) in enumerate(coefficients):
                c_indices[i] = index
                c_coeff[i] = coeff

        error = GRBaddvar(self.model, nonzeros, c_indices, c_coeff, obj, <double> lower_bound, <double> upper_bound, vtype, c_name)

        if coefficients is not None:
            sig_free(c_coeff)
            sig_free(c_indices)

        check(self.env,error)

        check(self.env,GRBupdatemodel(self.model))

        return self.ncols()-1

    IF HAVE_ADD_COL_UNTYPED_ARGS:
        cpdef add_col(self, indices, coeffs) noexcept:
            """
            Add a column.

            INPUT:

            - ``indices`` (list of integers) -- this list contains the
              indices of the constraints in which the variable's
              coefficient is nonzero

            - ``coeffs`` (list of real values) -- associates a coefficient
              to the variable in each of the constraints in which it
              appears. Namely, the i-th entry of ``coeffs`` corresponds to
              the coefficient of the variable in the constraint
              represented by the i-th entry in ``indices``.

            .. NOTE::

                ``indices`` and ``coeffs`` are expected to be of the same
                length.

            EXAMPLES::

                sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
                sage: p = GurobiBackend()
                sage: p.ncols()
                0
                sage: p.nrows()
                0
                sage: p.add_linear_constraints(5, 0, None)
                sage: p.add_col(list(range(5)), list(range(5)))
                sage: p.nrows()
                5
            """
            self.add_variable(coefficients = zip(indices, coeffs))
    ELSE:
        cpdef add_col(self, list indices, list coeffs) noexcept:
            """
            Add a column.

            INPUT:

            - ``indices`` (list of integers) -- this list contains the
              indices of the constraints in which the variable's
              coefficient is nonzero

            - ``coeffs`` (list of real values) -- associates a coefficient
              to the variable in each of the constraints in which it
              appears. Namely, the i-th entry of ``coeffs`` corresponds to
              the coefficient of the variable in the constraint
              represented by the i-th entry in ``indices``.

            .. NOTE::

                ``indices`` and ``coeffs`` are expected to be of the same
                length.

            """
            self.add_variable(coefficients = zip(indices, coeffs))

    cpdef set_variable_type(self, int variable, int vtype) noexcept:
        """
        Set the type of a variable

        INPUT:

        - ``variable`` (integer) -- the variable's id

        - ``vtype`` (integer) :

            *  1  Integer
            *  0  Binary
            * -1 Real

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.ncols()
            0
            sage: p.add_variable()
            0
            sage: p.set_variable_type(0,1)
            sage: p.is_variable_integer(0)
            True
        """
        cdef int error

        if vtype == 1:
            error = GRBsetcharattrelement(self.model, "VType", variable, 'I')
        elif vtype == 0:
            error = GRBsetcharattrelement(self.model, "VType", variable, 'B')
        else:
            error = GRBsetcharattrelement(self.model, "VType", variable, 'C')
        check(self.env, error)

        check(self.env,GRBupdatemodel(self.model))

    cpdef set_sense(self, int sense) noexcept:
        """
        Set the direction (maximization/minimization).

        INPUT:

        - ``sense`` (integer) :

            * +1 => Maximization
            * -1 => Minimization

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.is_maximization()
            True
            sage: p.set_sense(-1)
            sage: p.is_maximization()
            False
        """
        cdef int error

        if sense == 1:
            error = GRBsetintattr(self.model, "ModelSense", -1)
        else:
            error = GRBsetintattr(self.model, "ModelSense", +1)

        check(self.env, error)
        check(self.env,GRBupdatemodel(self.model))

    cpdef objective_coefficient(self, int variable, coeff=None) noexcept:
        """
        Set or get the coefficient of a variable in the objective function

        INPUT:

        - ``variable`` (integer) -- the variable's id

        - ``coeff`` (double) -- its coefficient or ``None`` for
          reading (default: ``None``)

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variable()
            0
            sage: p.objective_coefficient(0) == 0
            True
            sage: p.objective_coefficient(0,2)
            sage: p.objective_coefficient(0)
            2.0
        """
        cdef int error
        cdef double value[1]

        if coeff:
            error = GRBsetdblattrelement(self.model, "Obj", variable, coeff)
            check(self.env, error)
            check(self.env,GRBupdatemodel(self.model))
        else:
            error = GRBgetdblattrelement(self.model, "Obj", variable, value)
            check(self.env, error)
            return value[0]

    IF HAVE_SAGE_CPYTHON_STRING:
        cpdef problem_name(self, name=None) noexcept:
            """
            Return or define the problem's name

            INPUT:

            - ``name`` (``str``) -- the problem's name. When set to
              ``None`` (default), the method returns the problem's name.

            EXAMPLES::

                sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
                sage: p = GurobiBackend()
                sage: p.problem_name("There once was a french fry")
                sage: print(p.problem_name())
                There once was a french fry

            TESTS::

                sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
                sage: p = GurobiBackend()
                sage: print(p.problem_name())
            """
            cdef int error
            cdef char * pp_name[1]

            if name is not None:
                error = GRBsetstrattr(self.model, "ModelName", str_to_bytes(name))
                check(self.env, error)
                check(self.env,GRBupdatemodel(self.model))

            else:
                check(self.env,GRBgetstrattr(self.model, "ModelName", <char **> pp_name))
                if pp_name[0] == NULL:
                    value = ""
                else:
                    value = char_to_str(pp_name[0])

                return value
    ELSE:
        cpdef problem_name(self, char *name=NULL) noexcept:
            """
            Return or define the problem's name

            INPUT:

            - ``name`` (``str``) -- the problem's name. When set to
              ``None`` (default), the method returns the problem's name.

            """
            cdef int error
            cdef char * pp_name[1]

            if name != NULL:
                error = GRBsetstrattr(self.model, "ModelName", str_to_bytes(name))
                check(self.env, error)
                check(self.env,GRBupdatemodel(self.model))

            else:
                check(self.env,GRBgetstrattr(self.model, "ModelName", <char **> pp_name))
                if pp_name[0] == NULL:
                    value = ""
                else:
                    value = char_to_str(pp_name[0])

                return value

    cpdef set_objective(self, list coeff, d = 0.0) noexcept:
        """
        Set the objective function.

        INPUT:

        - ``coeff`` - a list of real values, whose ith element is the
          coefficient of the ith variable in the objective function.

        - ``d`` (double) -- the constant term in the linear function (set to `0` by default)

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(5)
            4
            sage: p.set_objective([1, 1, 2, 1, 3])
            sage: [p.objective_coefficient(x) for x in range(5)]
            [1.0, 1.0, 2.0, 1.0, 3.0]

        Constants in the objective function are respected::

            sage: p = MixedIntegerLinearProgram(solver=GurobiBackend)
            sage: v = p.new_variable(nonnegative=True)
            sage: x,y = v[0], v[1]
            sage: p.add_constraint(2*x + 3*y, max = 6)
            sage: p.add_constraint(3*x + 2*y, max = 6)
            sage: p.set_objective(x + y + 7)
            sage: p.set_integer(x); p.set_integer(y)
            sage: p.solve()
            9.0
        """
        cdef int i = 0
        cdef double value
        cdef int error

        for value in coeff:
            error = GRBsetdblattrelement (self.model, "Obj", i, value)
            check(self.env,error)
            i += 1

        check(self.env,GRBupdatemodel(self.model))

        self.obj_constant_term = d

    cpdef set_verbosity(self, int level) noexcept:
        """
        Set the verbosity level

        INPUT:

        - ``level`` (integer) -- From 0 (no verbosity) to 3.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.set_verbosity(2)
            Set parameter OutputFlag to value 1
        """
        cdef int error
        if level:
            error = GRBsetintparam(self.env, "OutputFlag", 1)
        else:
            error = GRBsetintparam(self.env, "OutputFlag", 0)

        check(self.env, error)

    cpdef remove_constraint(self, int i) noexcept:
        r"""
        Remove a constraint from self.

        INPUT:

        - ``i`` -- index of the constraint to remove

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = MixedIntegerLinearProgram(solver=GurobiBackend)
            sage: v = p.new_variable(nonnegative=True)
            sage: x,y = v[0], v[1]
            sage: p.add_constraint(2*x + 3*y, max = 6)
            sage: p.add_constraint(3*x + 2*y, max = 6)
            sage: p.set_objective(x + y + 7)
            sage: p.set_integer(x); p.set_integer(y)
            sage: p.solve()
            9.0
            sage: p.remove_constraint(0)
            sage: p.solve()
            10.0
            sage: p.get_values([x,y])                          # tol 1e-6
            [0.0, 3.0]
        """
        cdef int ind[1]
        ind[0] = i
        cdef int error
        error = GRBdelconstrs (self.model, 1, ind )
        check(self.env, error)

        #error = GRBupdatemodel(self.model)
        #check(self.env,error)

    cpdef add_linear_constraint(self, coefficients, lower_bound, upper_bound, name=None) noexcept:
        """
        Add a linear constraint.

        INPUT:

        - ``coefficients`` an iterable with ``(c,v)`` pairs where ``c``
          is a variable index (integer) and ``v`` is a value (real
          value).

        - ``lower_bound`` - a lower bound, either a real value or ``None``

        - ``upper_bound`` - an upper bound, either a real value or ``None``

        - ``name`` - an optional name for this row (default: ``None``)

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(5)
            4
            sage: p.add_linear_constraint( zip(range(5), range(1, 6)), 2.0, 2.0)
            sage: p.row(0)
            ([0, 1, 2, 3, 4], [1.0, 2.0, 3.0, 4.0, 5.0])
            sage: p.row_bounds(0)
            (2.0, 2.0)
            sage: p.add_linear_constraint( zip(range(5), range(5)), 1.0, 1.0, name='foo')
            sage: p.row_name(1)
            'foo'
        """

        if lower_bound is None and upper_bound is None:
            raise ValueError("at least one of 'upper_bound' or 'lower_bound' must be set")

        coefficients = list(coefficients)
        cdef int n = len(coefficients)
        cdef int * row_i
        cdef double * row_values

        row_i = <int *> sig_malloc(n * sizeof(int))
        row_values = <double *> sig_malloc(n * sizeof(double))


        for i,(c,v) in enumerate(coefficients):
            row_i[i] = c
            row_values[i] = v

        if name is None:
            name = ""

        if upper_bound is not None and lower_bound is None:
            error = GRBaddconstr(self.model, n, row_i, row_values, GRB_LESS_EQUAL, <double> upper_bound, str_to_bytes(name))

        elif lower_bound is not None and upper_bound is None:
            error = GRBaddconstr(self.model, n, row_i, row_values, GRB_GREATER_EQUAL, <double> lower_bound, str_to_bytes(name))

        elif upper_bound is not None and lower_bound is not None:
            if lower_bound == upper_bound:
                error = GRBaddconstr(self.model, n, row_i, row_values, GRB_EQUAL, <double> lower_bound, str_to_bytes(name))

            else:
                error = GRBaddrangeconstr(self.model, n, row_i, row_values, <double> lower_bound, <double> upper_bound, str_to_bytes(name))

        else:
            # This case is repeated here to avoid compilation warnings
            raise ValueError("at least one of 'upper_bound' or 'lower_bound' must be set")

        check(self.env,error)

        #error = GRBupdatemodel(self.model)

        #check(self.env,error)

        sig_free(row_i)
        sig_free(row_values)

    cpdef row(self, int index) noexcept:
        r"""
        Return a row

        INPUT:

        - ``index`` (integer) -- the constraint's id.

        OUTPUT:

        A pair ``(indices, coeffs)`` where ``indices`` lists the
        entries whose coefficient is nonzero, and to which ``coeffs``
        associates their coefficient on the model of the
        ``add_linear_constraint`` method.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(5)
            4
            sage: p.add_linear_constraint(zip(range(5), range(1, 6)), 2, 2)
            sage: p.row(0)
            ([0, 1, 2, 3, 4], [1.0, 2.0, 3.0, 4.0, 5.0])
        """
        cdef int error
        cdef int fake[1]

        cdef int length[1]
        error =  GRBgetconstrs(self.model, length, NULL, NULL, NULL, index, 1 )
        check(self.env,error)

        cdef int * p_indices = <int *> sig_malloc(length[0] * sizeof(int))
        cdef double * p_values = <double *> sig_malloc(length[0] * sizeof(double))

        error =  GRBgetconstrs(self.model, length, <int *> fake, p_indices, p_values, index, 1 )
        check(self.env,error)

        cdef list indices = []
        cdef list values = []

        cdef int i
        for i in range(length[0]):
            indices.append(p_indices[i])
            values.append(p_values[i])

        sig_free(p_indices)
        sig_free(p_values)

        return indices, values


    cpdef row_bounds(self, int index) noexcept:
        """
        Return the bounds of a specific constraint.

        INPUT:

        - ``index`` (integer) -- the constraint's id.

        OUTPUT:

        A pair ``(lower_bound, upper_bound)``. Each of them can be set
        to ``None`` if the constraint is not bounded in the
        corresponding direction, and is a real value otherwise.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(5)
            4
            sage: p.add_linear_constraint(zip(range(5), range(1, 6)), 2, 2)
            sage: p.row_bounds(0)
            (2.0, 2.0)
        """
        cdef double d[1]
        cdef char sense[1]
        cdef int error

        error = GRBgetcharattrelement(self.model, "Sense", index, <char *> sense)
        check(self.env, error)

        error = GRBgetdblattrelement(self.model, "RHS", index, <double *> d)
        check(self.env, error)

        if sense[0] == '>':
            return (d[0], None)
        elif sense[0] == '<':
            return (None, d[0])
        else:
            return (d[0],d[0])

    cpdef col_bounds(self, int index) noexcept:
        """
        Return the bounds of a specific variable.

        INPUT:

        - ``index`` (integer) -- the variable's id.

        OUTPUT:

        A pair ``(lower_bound, upper_bound)``. Each of them can be set
        to ``None`` if the variable is not bounded in the
        corresponding direction, and is a real value otherwise.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variable()
            0
            sage: p.col_bounds(0)
            (0.0, None)
            sage: p.variable_upper_bound(0, 5)
            sage: p.col_bounds(0)
            (0.0, 5.0)
        """
        cdef double lb[1]
        cdef double ub[1]

        error = GRBgetdblattrelement(self.model, "LB", index, <double *> lb)
        check(self.env, error)

        error = GRBgetdblattrelement(self.model, "UB", index, <double *> ub)
        check(self.env, error)

        return (None if lb[0] <= -GRB_INFINITY else lb[0],
                None if  ub[0] >= GRB_INFINITY else ub[0])

    cpdef int solve(self) except -1:
        """
        Solve the problem.

        .. NOTE::

            This method raises ``MIPSolverException`` exceptions when
            the solution can not be computed for any reason (none
            exists, or the LP solver was not able to find it, etc...)

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(5)
            4
            sage: p.add_linear_constraint([(0,1), (1, 1)], 1.2, 1.7)
            sage: p.set_variable_type(0, 1)
            sage: p.set_variable_type(1, 1)
            sage: p.solve()
            Traceback (most recent call last):
            ...
            MIPSolverException: Gurobi: The problem is infeasible
        """
        cdef int error
        global mip_status

        check(self.env, GRBoptimize(self.model))

        cdef int status[1]
        check(self.env, GRBgetintattr(self.model, "Status", <int *> status))

        # Has there been a problem ?
        if status[0] != GRB_OPTIMAL:
            raise MIPSolverException("Gurobi: "+mip_status.get(status[0], "unknown error during call to GRBoptimize : "+str(status[0])))


    cpdef get_objective_value(self) noexcept:
        """
        Returns the value of the objective function.

        .. NOTE::

           Behaviour is undefined unless ``solve`` has been called before.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(2)
            1
            sage: p.add_linear_constraint([[0, 1], [1, 2]], None, 3)
            sage: p.set_objective([2, 5])
            sage: p.solve()
            0
            sage: p.get_objective_value()
            7.5
            sage: p.get_variable_value(0)
            0.0
            sage: p.get_variable_value(1)
            1.5
        """
        cdef double p_value[1]

        check(self.env,GRBgetdblattr(self.model, "ObjVal", <double* >p_value))

        return p_value[0] + <double>self.obj_constant_term

    cpdef get_variable_value(self, int variable) noexcept:
        """
        Returns the value of a variable given by the solver.

        .. NOTE::

           Behaviour is undefined unless ``solve`` has been called before.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variables(2)
            1
            sage: p.add_linear_constraint([[0, 1], [1, 2]], None, 3)
            sage: p.set_objective([2, 5])
            sage: p.solve()
            0
            sage: p.get_objective_value()
            7.5
            sage: p.get_variable_value(0)
            0.0
            sage: p.get_variable_value(1)
            1.5
        """

        cdef double value[1]
        check(self.env,GRBgetdblattrelement(self.model, "X", variable, value))
        if self.is_variable_continuous(variable):
            return value[0]
        else:
            return round(value[0])

    cpdef int ncols(self) noexcept:
        """
        Return the number of columns/variables.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.ncols()
            0
            sage: p.add_variables(2)
            1
            sage: p.ncols()
            2
        """
        cdef int i[1]
        check(self.env,GRBgetintattr(self.model, "NumVars", i))
        return i[0]

    cpdef int nrows(self) noexcept:
        """
        Return the number of rows/constraints.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.nrows()
            0
            sage: p.add_linear_constraint([], 2, None)
            sage: p.add_linear_constraint([], 2, None)
            sage: p.nrows()
            2
        """
        cdef int i[1]
        check(self.env,GRBgetintattr(self.model, "NumConstrs", i))
        return i[0]

    cpdef col_name(self, int index) noexcept:
        """
        Return the ``index`` th col name

        INPUT:

        - ``index`` (integer) -- the col's id

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variable(name='I am a variable')
            0
            sage: p.col_name(0)
            'I am a variable'
        """
        cdef char * name[1]
        check(self.env,GRBgetstrattrelement(self.model, "VarName", index, <char **> name))
        if name[0] == NULL:
            value = ""
        else:
            value = char_to_str(name[0])
        return value

    cpdef row_name(self, int index) noexcept:
        """
        Return the ``index`` th row name

        INPUT:

        - ``index`` (integer) -- the row's id

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_linear_constraint([], 2, None, name='Empty constraint 1')
            sage: p.row_name(0)
            'Empty constraint 1'
        """
        cdef char * name[1]
        check(self.env,GRBgetstrattrelement(self.model, "ConstrName", index, <char **> name))
        if name[0] == NULL:
            value = ""
        else:
            value = char_to_str(name[0])
        return value

    cpdef bint is_variable_binary(self, int index) noexcept:
        """
        Test whether the given variable is of binary type.

        INPUT:

        - ``index`` (integer) -- the variable's id

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.ncols()
            0
            sage: p.add_variable()
            0
            sage: p.set_variable_type(0,0)
            sage: p.is_variable_binary(0)
            True
        """
        cdef char vtype[1]
        check(self.env, GRBgetcharattrelement(self.model, "VType", index, <char *> vtype))
        return vtype[0] == 'B'


    cpdef bint is_variable_integer(self, int index) noexcept:
        """
        Test whether the given variable is of integer type.

        INPUT:

        - ``index`` (integer) -- the variable's id

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.ncols()
            0
            sage: p.add_variable()
            0
            sage: p.set_variable_type(0,1)
            sage: p.is_variable_integer(0)
            True
        """
        cdef char vtype[1]
        check(self.env, GRBgetcharattrelement(self.model, "VType", index, <char *> vtype))
        return vtype[0] == 'I'

    cpdef bint is_variable_continuous(self, int index) noexcept:
        """
        Test whether the given variable is of continuous/real type.

        INPUT:

        - ``index`` (integer) -- the variable's id

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.ncols()
            0
            sage: p.add_variable()
            0
            sage: p.is_variable_continuous(0)
            True
            sage: p.set_variable_type(0,1)
            sage: p.is_variable_continuous(0)
            False

        """
        cdef char vtype[1]
        check(self.env, GRBgetcharattrelement(self.model, "VType", index, <char *> vtype))
        return vtype[0] == 'C'

    cpdef bint is_maximization(self) noexcept:
        """
        Test whether the problem is a maximization

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.is_maximization()
            True
            sage: p.set_sense(-1)
            sage: p.is_maximization()
            False
        """
        cdef int sense[1]
        check(self.env,GRBgetintattr(self.model, "ModelSense", <int *> sense))
        return sense[0] == -1

    cpdef variable_upper_bound(self, int index, value = False) noexcept:
        """
        Return or define the upper bound on a variable

        INPUT:

        - ``index`` (integer) -- the variable's id

        - ``value`` -- real value, or ``None`` to mean that the
          variable has not upper bound. When set to ``False``
          (default), the method returns the current value.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variable()
            0
            sage: p.col_bounds(0)
            (0.0, None)
            sage: p.variable_upper_bound(0, 5)
            sage: p.col_bounds(0)
            (0.0, 5.0)
        """
        cdef double b[1]

        if not value is False:
            check(self.env, GRBsetdblattrelement(
                    self.model, "UB",
                    index,
                    value if value is not None else GRB_INFINITY))

            check(self.env,GRBupdatemodel(self.model))
        else:
            error = GRBgetdblattrelement(self.model, "UB", index, <double *> b)
            check(self.env, error)
            return None if b[0] >= GRB_INFINITY else b[0]

    cpdef variable_lower_bound(self, int index, value = False) noexcept:
        """
        Return or define the lower bound on a variable

        INPUT:

        - ``index`` (integer) -- the variable's id

        - ``value`` -- real value, or ``None`` to mean that the
          variable has not lower bound. When set to ``False``
          (default), the method returns the current value.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = GurobiBackend()
            sage: p.add_variable()
            0
            sage: p.col_bounds(0)
            (0.0, None)
            sage: p.variable_lower_bound(0, 5)
            sage: p.col_bounds(0)
            (5.0, None)
        """
        cdef double b[1]


        if not value is False:
            check(self.env, GRBsetdblattrelement(
                    self.model, "LB",
                    index,
                    value if value is not None else -GRB_INFINITY))

            check(self.env,GRBupdatemodel(self.model))

        else:
            error = GRBgetdblattrelement(self.model, "LB", index, <double *> b)
            check(self.env, error)
            return None if b[0] <= -GRB_INFINITY else b[0]

    IF HAVE_SAGE_CPYTHON_STRING:
        cpdef write_lp(self, filename) noexcept:
            """
            Write the problem to a .lp file

            INPUT:

            - ``filename`` (string)

            EXAMPLES::

                sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
                sage: import tempfile
                sage: p = GurobiBackend()
                sage: p.add_variables(2)
                1
                sage: p.add_linear_constraint([[0, 1], [1, 2]], None, 3)
                sage: p.set_objective([2, 5])
                sage: with tempfile.TemporaryDirectory() as f:
                ....:     p.write_lp(os.path.join(f, "lp_problem.lp"))
            """
            filename = str_to_bytes(filename, FS_ENCODING, 'surrogateescape')
            check(self.env, GRBwrite(self.model, filename))

        cpdef write_mps(self, filename, int modern) noexcept:
            """
            Write the problem to a .mps file

            INPUT:

            - ``filename`` (string)

            EXAMPLES::

                sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
                sage: import tempfile
                sage: p = GurobiBackend()
                sage: p.add_variables(2)
                1
                sage: p.add_linear_constraint([[0, 1], [1, 2]], None, 3)
                sage: p.set_objective([2, 5])
                sage: with tempfile.TemporaryDirectory() as f:
                ....:     p.write_lp(os.path.join(f, "lp_problem.lp"))
            """
            filename = str_to_bytes(filename, FS_ENCODING, 'surrogateescape')
            check(self.env, GRBwrite(self.model, filename))
    ELSE:
        cpdef write_lp(self, char *filename) noexcept:
            """
            Write the problem to a .lp file

            INPUT:

            - ``filename`` (string)

            """
            check(self.env, GRBwrite(self.model, filename))

        cpdef write_mps(self, char *filename, int modern) noexcept:
            """
            Write the problem to a .mps file

            INPUT:

            - ``filename`` (string)

            """
            check(self.env, GRBwrite(self.model, filename))


    cpdef solver_parameter(self, name, value = None) noexcept:
        """
        Returns or defines a solver parameter.

        For a list of parameters and associated values, please refer to Gurobi's
        reference manual
        `<http://www.gurobi.com/documentation/5.5/reference-manual/node798>`_.

        INPUT:

        - ``name`` (string) -- the parameter

        - ``value`` -- the parameter's value if it is to be defined,
          or ``None`` (default) to obtain its current value.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = MixedIntegerLinearProgram(solver=GurobiBackend)

        An integer parameter::

            sage: p.solver_parameter("VarBranch")
            -1
            sage: p.solver_parameter("VarBranch", 1)
            sage: p.solver_parameter("VarBranch")
            1

        A double parameter::

            sage: p.solver_parameter("TimeLimit")
            1e+100
            sage: p.solver_parameter("TimeLimit", 10)
            sage: p.solver_parameter("TimeLimit")
            10.0

        A string parameter::

            sage: p.solver_parameter("LogFile")
            ''
            sage: p.solver_parameter("LogFile", "/dev/null")
            sage: p.solver_parameter("LogFile")
            '/dev/null'

        """
        cdef int    tmp_int[1]
        cdef double tmp_dbl[1]
        cdef char   tmp_str[25500]
        cdef char * c_name
        c_name = tmp_str

        if name == "timelimit":
            name = "TimeLimit"
        elif name.lower() == "logfile":
            name = "LogFile"

        try:
            t = parameters_type[name]
        except KeyError:
            raise ValueError("This parameter is not available. "+
                             "Enabling it may not be so hard, though.")

        name = str_to_bytes(name)

        if t == "int":
            if value is None:
                check(self.env, GRBgetintparam(self.env, name, tmp_int))
                return tmp_int[0]
            else:
                check(self.env, GRBsetintparam(self.env, name, value))
        elif t == "double":
            if value is None:
                check(self.env, GRBgetdblparam(self.env, name, tmp_dbl))
                return tmp_dbl[0]
            else:
                check(self.env, GRBsetdblparam(self.env, name, value))
        elif t == "string":
            if value is None:
                check(self.env, GRBgetstrparam(self.env, name, c_name))
                return char_to_str(c_name)
            else:
                check(self.env, GRBsetstrparam(self.env, name, str_to_bytes(value)))
        else:
            raise RuntimeError("This should not happen.")

    cpdef __copy__(self) noexcept:
        """
        Returns a copy of self.

        EXAMPLES::

            sage: from sage_numerical_backends_gurobi.gurobi_backend import GurobiBackend
            sage: p = MixedIntegerLinearProgram(solver=GurobiBackend)
            sage: b = p.new_variable(nonnegative=True)
            sage: p.add_constraint(b[1] + b[2] <= 6)
            sage: p.set_objective(b[1] + b[2])
            sage: copy(p).solve()
            6.0
        """
        cdef GurobiBackend p = type(self)(maximization = self.is_maximization())
        p.model = GRBcopymodel(self.model)
        p.env = GRBgetenv(p.model)
        # Gurobi appends '_copy' to the problem name and does not even hesitate to create '(null)_copy'
        name = self.problem_name()
        p.problem_name(name)
        return p

    def __dealloc__(self):
        """
        Destructor
        """
        GRBfreemodel(self.model)
        GRBfreeenv(self.env_master)

cdef dict errors = {
    10001 : "GRB_ERROR_OUT_OF_MEMORY",
    10002 : "GRB_ERROR_NULL_ARGUMENT",
    10003 : "GRB_ERROR_INVALID_ARGUMENT",
    10004 : "GRB_ERROR_UNKNOWN_ATTRIBUTE",
    10005 : "GRB_ERROR_DATA_NOT_AVAILABLE",
    10006 : "GRB_ERROR_INDEX_OUT_OF_RANGE",
    10007 : "GRB_ERROR_UNKNOWN_PARAMETER",
    10008 : "GRB_ERROR_VALUE_OUT_OF_RANGE",
    10009 : "GRB_ERROR_NO_LICENSE",
    10010 : "GRB_ERROR_SIZE_LIMIT_EXCEEDED",
    10011 : "GRB_ERROR_CALLBACK",
    10012 : "GRB_ERROR_FILE_READ",
    10013 : "GRB_ERROR_FILE_WRITE",
    10014 : "GRB_ERROR_NUMERIC",
    10015 : "GRB_ERROR_IIS_NOT_INFEASIBLE",
    10016 : "GRB_ERROR_NOT_FOR_MIP",
    10017 : "GRB_ERROR_OPTIMIZATION_IN_PROGRESS",
    10018 : "GRB_ERROR_DUPLICATES",
    10019 : "GRB_ERROR_NODEFILE",
    10020 : "GRB_ERROR_Q_NOT_PSD",
}

cdef dict mip_status = {
    GRB_INFEASIBLE: "The problem is infeasible",
    GRB_INF_OR_UNBD: "The problem is infeasible or unbounded",
    GRB_UNBOUNDED: "The problem is unbounded",
    GRB_ITERATION_LIMIT: "The iteration limit has been reached",
    GRB_NODE_LIMIT: "The node limit has been reached",
    GRB_TIME_LIMIT: "The time limit has been reached",
    GRB_SOLUTION_LIMIT: "The solution limit has been reached",
}

cdef dict parameters_type = {
    "AggFill"           : "int",
    "Aggregate"         : "int",
    "BarConvTol"        : "double",
    "BarCorrectors"     : "int",
    "BarHomogeneous"    : "int",
    "BarOrder"          : "int",
    "BarQCPConvTol"     : "double",
    "BarIterLimit"      : "int",
    "BranchDir"         : "int",
    "CliqueCuts"        : "int",
    "CoverCuts"         : "int",
    "Crossover"         : "int",
    "CrossoverBasis"    : "int",
    "Cutoff"            : "double",
    "CutAggPasses"      : "int",
    "CutPasses"         : "int",
    "Cuts"              : "int",
    "DisplayInterval"   : "int",
    "DualReductions"    : "int",
    "FeasibilityTol"    : "double",
    "FeasRelaxBigM"     : "double",
    "FlowCoverCuts"     : "int",
    "FlowPathCuts"      : "int",
    "GomoryPasses"      : "int",
    "GUBCoverCuts"      : "int",
    "Heuristics"        : "double",
    "IISMethod"         : "int",
    "ImpliedCuts"       : "int",
    "ImproveStartGap"   : "double",
    "ImproveStartNodes" : "double",
    "ImproveStartTime"  : "double",
    "InfUnbdInfo"       : "int",
    "IntegralityFocus"  : "int",
    "InputFile"         : "string",
    "IntFeasTol"        : "double",
    "IterationLimit"    : "double",
    "LogFile"           : "string",
    "LogToConsole"      : "int",
    "MarkowitzTol"      : "double",
    "Method"            : "int",
    "MinRelNodes"       : "int",
    "MIPFocus"          : "int",
    "MIPGap"            : "double",
    "MIPGapAbs"         : "double",
    "MIPSepCuts"        : "int",
    "MIQCPMethod"       : "int",
    "MIRCuts"           : "int",
    "ModKCuts"          : "int",
    "NetworkCuts"       : "int",
    "NodefileDir"       : "string",
    "NodefileStart"     : "double",
    "NodeLimit"         : "double",
    "NodeMethod"        : "int",
    "NormAdjust"        : "int",
    "ObjScale"          : "double",
    "OptimalityTol"     : "double",
    "OutputFlag"        : "int",
    "PerturbValue"      : "double",
    "PreCrush"          : "int",
    "PreDepRow"         : "int",
    "PreDual"           : "int",
    "PrePasses"         : "int",
    "PreQLinearize"     : "int",
    "Presolve"          : "int",
    "PreSparsify"       : "int",
    "PSDTol"            : "double",
    "PumpPasses"        : "int",
    "QCPDual"           : "int",
    "Quad"              : "int",
    "ResultFile"        : "string",
    "RINS"              : "int",
    "ScaleFlag"         : "int",
    "Seed"              : "int",
    "Sifting"           : "int",
    "SiftMethod"        : "int",
    "SimplexPricing"    : "int",
    "SolutionLimit"     : "int",
    "SolutionNumber"    : "int",
    "SubMIPCuts"        : "int",
    "SubMIPNodes"       : "int",
    "Symmetry"          : "int",
    "Threads"           : "int",
    "TimeLimit"         : "double",
    "VarBranch"         : "int",
    "ZeroHalfCuts"      : "int",
    "ZeroObjNodes"      : "int"
    }

cdef check(GRBenv * env, int error):
    if error:
        raise MIPSolverException("Gurobi: "+str(GRBgeterrormsg(env))+" ("+errors[error]+")")
