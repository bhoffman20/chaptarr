import PropTypes from 'prop-types';
import React, { Component } from 'react';
import { connect } from 'react-redux';
import { createSelector } from 'reselect';
import * as bookInfiniteScrollActions from 'Store/Actions/bookInfiniteScrollActions';
import getBookIndexQuery from './getBookIndexQuery';

// Gives a book index list view (Table, Overview) the server-paged books the Posters view uses,
// so a large library is loaded a page at a time instead of all at once.
function createMapStateToProps() {
  return createSelector(
    (state) => state.bookIndex,
    (state) => state.bookInfiniteScroll,
    (state) => state.app.selectedMediaType,
    (bookIndex, bookInfiniteScroll, selectedMediaType) => {
      const { queryKey, queryParams } = getBookIndexQuery(bookIndex, selectedMediaType);
      const query = bookInfiniteScroll.queries[queryKey] || {};

      return {
        queryKey,
        queryParams,
        totalCount: query.totalCount,
        pages: query.pages || {},
        entities: bookInfiniteScroll.entities || {},
        pageSize: bookInfiniteScroll.pageSize
      };
    }
  );
}

const mapDispatchToProps = {
  dispatchSetActiveQuery: bookInfiniteScrollActions.setActiveQuery,
  dispatchInvalidateQuery: bookInfiniteScrollActions.invalidateQuery,
  dispatchFetchBuckets: bookInfiniteScrollActions.fetchBookBuckets,
  dispatchFetchBooksForIndexRange: bookInfiniteScrollActions.fetchBooksForIndexRange,
  dispatchJumpToLetter: bookInfiniteScrollActions.jumpToLetter,
  dispatchAbortAllRequests: bookInfiniteScrollActions.abortAllRequests
};

function withInfiniteBooks(WrappedComponent) {
  class InfiniteBooks extends Component {

    //
    // Lifecycle

    constructor(props, context) {
      super(props, context);

      this.state = {
        scrollToIndex: null
      };
    }

    componentDidMount() {
      this.startQuery();
    }

    componentDidUpdate(prevProps) {
      const {
        queryKey,
        jumpToCharacter
      } = this.props;

      if (prevProps.queryKey !== queryKey) {
        this.props.dispatchInvalidateQuery(prevProps.queryKey);
        this.startQuery();
      }

      if (jumpToCharacter != null && jumpToCharacter !== prevProps.jumpToCharacter) {
        this.jumpToCharacter(jumpToCharacter);
      }
    }

    componentWillUnmount() {
      this.props.dispatchAbortAllRequests();
    }

    //
    // Control

    startQuery() {
      const {
        queryKey,
        queryParams,
        pageSize
      } = this.props;

      this.props.dispatchSetActiveQuery({ queryKey, queryParams });
      this.props.dispatchFetchBuckets({ queryKey });
      this.props.dispatchFetchBooksForIndexRange({
        queryKey,
        startIndex: 0,
        stopIndex: pageSize * 2 - 1
      });
    }

    jumpToCharacter(letter) {
      const { queryKey } = this.props;

      this.props.dispatchJumpToLetter({ queryKey, letter }).then(({ targetIndex }) => {
        // Ignore the result if the query changed while the jump was loading.
        if (queryKey === this.props.queryKey) {
          // Clear first so jumping to the same letter again still scrolls.
          this.setState({ scrollToIndex: null }, () => {
            this.setState({ scrollToIndex: targetIndex });
          });
        }
      });
    }

    getBookAtIndex = (index) => {
      const {
        pages,
        entities,
        pageSize
      } = this.props;

      const page = pages[Math.floor(index / pageSize)];
      const id = page?.ids?.[index % pageSize];

      return id ? entities[id] : undefined;
    };

    //
    // Listeners

    onRowsRendered = ({ startIndex, stopIndex }) => {
      const { queryKey } = this.props;

      this.props.dispatchFetchBooksForIndexRange({ queryKey, startIndex, stopIndex });
    };

    //
    // Render

    render() {
      const {
        totalCount,
        jumpToCharacter,
        queryKey,
        queryParams,
        pages,
        entities,
        pageSize,
        dispatchSetActiveQuery,
        dispatchInvalidateQuery,
        dispatchFetchBuckets,
        dispatchFetchBooksForIndexRange,
        dispatchJumpToLetter,
        dispatchAbortAllRequests,
        ...otherProps
      } = this.props;

      return (
        <WrappedComponent
          {...otherProps}
          rowCount={totalCount ?? 0}
          getBookAtIndex={this.getBookAtIndex}
          scrollToIndex={this.state.scrollToIndex}
          onRowsRendered={this.onRowsRendered}
        />
      );
    }
  }

  InfiniteBooks.propTypes = {
    jumpToCharacter: PropTypes.string,
    queryKey: PropTypes.string.isRequired,
    queryParams: PropTypes.object.isRequired,
    totalCount: PropTypes.number,
    pages: PropTypes.object.isRequired,
    entities: PropTypes.object.isRequired,
    pageSize: PropTypes.number.isRequired,
    dispatchSetActiveQuery: PropTypes.func.isRequired,
    dispatchInvalidateQuery: PropTypes.func.isRequired,
    dispatchFetchBuckets: PropTypes.func.isRequired,
    dispatchFetchBooksForIndexRange: PropTypes.func.isRequired,
    dispatchJumpToLetter: PropTypes.func.isRequired,
    dispatchAbortAllRequests: PropTypes.func.isRequired
  };

  return connect(createMapStateToProps, mapDispatchToProps)(InfiniteBooks);
}

export default withInfiniteBooks;
