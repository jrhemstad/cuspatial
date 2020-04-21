/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <thrust/iterator/discard_iterator.h>

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/table/table.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <cuspatial/detail/trajectory.hpp>

namespace cuspatial {
namespace experimental {

namespace {

struct dispatch_element {
  template <typename Element>
  std::enable_if_t<std::is_floating_point<Element>::value,
                   std::unique_ptr<cudf::experimental::table>>
  operator()(cudf::column_view const& object_id, cudf::column_view const& x,
             cudf::column_view const& y, rmm::mr::device_memory_resource* mr,
             cudaStream_t stream) {
    auto policy = rmm::exec_policy(stream);

    // Compute output column size
    auto size = [&]() {
      rmm::device_vector<int32_t> unique_keys(object_id.size());
      auto last_key_pos =
          thrust::unique_copy(policy->on(stream), object_id.begin<int32_t>(),
                              object_id.end<int32_t>(), unique_keys.begin());
      return thrust::distance(unique_keys.begin(), last_key_pos);
    }();

    // Construct output columns
    auto type = cudf::data_type{cudf::experimental::type_to_id<Element>()};
    std::vector<std::unique_ptr<cudf::column>> cols{};
    cols.reserve(4);
    // allocate bbox_x1 output column
    cols.push_back(cudf::make_numeric_column(
        type, size, cudf::mask_state::UNALLOCATED, stream, mr));
    // allocate bbox_y1 output column
    cols.push_back(cudf::make_numeric_column(
        type, size, cudf::mask_state::UNALLOCATED, stream, mr));
    // allocate bbox_x2 output column
    cols.push_back(cudf::make_numeric_column(
        type, size, cudf::mask_state::UNALLOCATED, stream, mr));
    // allocate bbox_y2 output column
    cols.push_back(cudf::make_numeric_column(
        type, size, cudf::mask_state::UNALLOCATED, stream, mr));

    auto points = thrust::make_zip_iterator(
        thrust::make_tuple(x.begin<Element>(), y.begin<Element>(),
                           x.begin<Element>(), y.begin<Element>()));

    auto bboxes = thrust::make_zip_iterator(thrust::make_tuple(
        cols.at(0)->mutable_view().begin<Element>(),  // bbox_x1
        cols.at(1)->mutable_view().begin<Element>(),  // bbox_y1
        cols.at(2)->mutable_view().begin<Element>(),  // bbox_x2
        cols.at(3)->mutable_view().begin<Element>())  // bbox_y2
    );

    thrust::fill(policy->on(stream), bboxes, bboxes + size,
                 thrust::make_tuple(std::numeric_limits<Element>::max(),
                                    std::numeric_limits<Element>::max(),
                                    std::numeric_limits<Element>::min(),
                                    std::numeric_limits<Element>::min()));

    thrust::reduce_by_key(policy->on(stream),               // execution policy
                          object_id.begin<int32_t>(),       // keys_first
                          object_id.end<int32_t>(),         // keys_last
                          points,                           // values_first
                          thrust::make_discard_iterator(),  // keys_output
                          bboxes,                           // values_output
                          thrust::equal_to<int32_t>(),      // binary_pred
                          [] __device__(auto a, auto b) {   // binary_op
                            Element x1, y1, x2, y2, x3, y3, x4, y4;
                            thrust::tie(x1, y1, x2, y2) = a;
                            thrust::tie(x3, y3, x4, y4) = b;
                            return thrust::make_tuple(
                                min(min(x1, x2), x3), min(min(y1, y2), y3),
                                max(max(x1, x2), x4), max(max(y1, y2), y4));
                          });

    // check for errors
    CHECK_CUDA(stream);

    return std::make_unique<cudf::experimental::table>(std::move(cols));
  }

  template <typename Element>
  std::enable_if_t<not std::is_floating_point<Element>::value,
                   std::unique_ptr<cudf::experimental::table>>
  operator()(cudf::column_view const& object_id, cudf::column_view const& x,
             cudf::column_view const& y, rmm::mr::device_memory_resource* mr,
             cudaStream_t stream) {
    CUSPATIAL_FAIL("X and Y must be floating point types");
  }
};

}  // namespace

namespace detail {
std::unique_ptr<cudf::experimental::table> trajectory_bounding_boxes(
    cudf::column_view const& object_id, cudf::column_view const& x,
    cudf::column_view const& y, rmm::mr::device_memory_resource* mr,
    cudaStream_t stream) {
  return cudf::experimental::type_dispatcher(x.type(), dispatch_element{},
                                             object_id, x, y, mr, stream);
}
}  // namespace detail

std::unique_ptr<cudf::experimental::table> trajectory_bounding_boxes(
    cudf::column_view const& object_id, cudf::column_view const& x,
    cudf::column_view const& y, rmm::mr::device_memory_resource* mr) {
  CUSPATIAL_EXPECTS(object_id.size() == x.size() && x.size() == y.size(),
                    "Data size mismatch");
  CUSPATIAL_EXPECTS(x.type().id() == y.type().id(), "Data type mismatch");
  CUSPATIAL_EXPECTS(object_id.type().id() == cudf::INT32,
                    "Invalid object_id type");
  CUSPATIAL_EXPECTS(!(x.has_nulls() || y.has_nulls() || object_id.has_nulls()),
                    "NULL support unimplemented");

  if (object_id.is_empty() || x.is_empty() || y.is_empty()) {
    std::vector<std::unique_ptr<cudf::column>> cols(4);
    cols.push_back(cudf::experimental::empty_like(x));
    cols.push_back(cudf::experimental::empty_like(y));
    cols.push_back(cudf::experimental::empty_like(x));
    cols.push_back(cudf::experimental::empty_like(y));
    return std::make_unique<cudf::experimental::table>(std::move(cols));
  }

  return detail::trajectory_bounding_boxes(object_id, x, y, mr, 0);
}

}  // namespace experimental
}  // namespace cuspatial
