#pragma once
// Compact "lower-case full path -> record index" map for SearchEngine::pathIndex_.
//
// std::unordered_map<std::string, uint32_t> cost ~180-240 bytes per file
// (node + heap-allocated key + bucket) and duplicated every full path that the
// engine already stores in its path/name pools. With millions of files that was
// the single biggest memory consumer (~0.5 GB for 2.5M files).
//
// This map keeps only a 64-bit hash of the key (open addressing, ~17 bytes per
// slot, ~65 MB for 2.5M files). Iteration therefore yields the hash, not the
// path; callers that need the path rebuild it from the engine's pools.
//
// Hash collisions: with 64-bit hashes the chance of any collision among
// 2.5 million paths is ~2e-7. A collision would make two paths share one entry
// (the later insert wins), i.e. at worst one file missing from results until
// the next rescan. That trade-off is accepted for a ~0.5 GB saving.

#include <cstdint>
#include <string_view>
#include <utility>
#include <vector>

class PathIndexMap {
public:
    using key_type = uint64_t;
    using value_type = std::pair<uint64_t, uint32_t>;

    static uint64_t hashKey(std::string_view s) {
        // FNV-1a 64 with a final avalanche mix
        uint64_t h = 1469598103934665603ull;
        for (unsigned char c : s) { h ^= c; h *= 1099511628211ull; }
        h ^= h >> 33; h *= 0xff51afd7ed558ccdull;
        h ^= h >> 33; h *= 0xc4ceb9fe1a85ec53ull;
        h ^= h >> 33;
        return h;
    }

    template <bool Const>
    class Iter {
        using MapPtr = std::conditional_t<Const, const PathIndexMap*, PathIndexMap*>;
        using Ref = std::conditional_t<Const, const value_type&, value_type&>;
        using Ptr = std::conditional_t<Const, const value_type*, value_type*>;
    public:
        Iter() = default;
        Iter(MapPtr m, size_t i) : m_(m), i_(i) { skip(); }
        template <bool C2 = Const, typename = std::enable_if_t<C2>>
        Iter(const Iter<false>& o) : m_(o.m_), i_(o.i_) {}
        Ref operator*() const { return m_->slots_[i_]; }
        Ptr operator->() const { return &m_->slots_[i_]; }
        Iter& operator++() { ++i_; skip(); return *this; }
        bool operator==(const Iter& o) const { return i_ == o.i_; }
        bool operator!=(const Iter& o) const { return i_ != o.i_; }
    private:
        friend class PathIndexMap;
        template <bool> friend class Iter;
        void skip() { while (m_ && i_ < m_->state_.size() && m_->state_[i_] != kLive) ++i_; }
        MapPtr m_ = nullptr;
        size_t i_ = 0;
    };
    using iterator = Iter<false>;
    using const_iterator = Iter<true>;

    size_t size() const { return size_; }
    bool empty() const { return size_ == 0; }

    void clear() {
        std::vector<value_type>().swap(slots_);
        std::vector<uint8_t>().swap(state_);
        size_ = 0;
        used_ = 0;
    }

    void reserve(size_t n) {
        size_t want = capacityFor(n);
        if (want > slots_.size()) rehash(want);
    }

    iterator begin() { return iterator(this, 0); }
    iterator end() { return iterator(this, slots_.size()); }
    const_iterator begin() const { return const_iterator(this, 0); }
    const_iterator end() const { return const_iterator(this, slots_.size()); }

    iterator find(std::string_view key) { return findHash(hashKey(key)); }
    const_iterator find(std::string_view key) const { return findHash(hashKey(key)); }
    iterator find(uint64_t h) { return findHash(h); }
    const_iterator find(uint64_t h) const { return findHash(h); }
    // Disambiguate string literals / std::string
    iterator find(const char* key) { return find(std::string_view(key)); }

    size_t count(std::string_view key) const { return find(key) != end() ? 1 : 0; }

    uint32_t& operator[](std::string_view key) { return valueFor(hashKey(key)); }
    uint32_t& operator[](const char* key) { return valueFor(hashKey(key)); }

    /// Erase by position; returns the iterator following it.
    iterator erase(iterator it) {
        size_t i = it.i_;
        if (i < state_.size() && state_[i] == kLive) {
            state_[i] = kDeleted;
            size_--;
        }
        return iterator(this, i + 1);
    }
    size_t erase(std::string_view key) { return eraseHash(hashKey(key)); }
    size_t erase(uint64_t h) { return eraseHash(h); }
    size_t erase(const char* key) { return eraseHash(hashKey(key)); }

    size_t memoryBytes() const {
        return slots_.capacity() * sizeof(value_type) + state_.capacity();
    }

private:
    static constexpr uint8_t kEmpty = 0, kLive = 1, kDeleted = 2;

    static size_t capacityFor(size_t n) {
        size_t need = n + n / 3 + 16; // load factor <= 0.75
        size_t cap = 16;
        while (cap < need) cap <<= 1;
        return cap;
    }

    size_t slotFor(uint64_t h) const {
        if (slots_.empty()) return SIZE_MAX;
        size_t mask = slots_.size() - 1;
        for (size_t i = static_cast<size_t>(h) & mask;; i = (i + 1) & mask) {
            if (state_[i] == kEmpty) return SIZE_MAX;
            if (state_[i] == kLive && slots_[i].first == h) return i;
        }
    }

    iterator findHash(uint64_t h) {
        size_t i = slotFor(h);
        return i == SIZE_MAX ? end() : iterator(this, i);
    }
    const_iterator findHash(uint64_t h) const {
        size_t i = slotFor(h);
        return i == SIZE_MAX ? end() : const_iterator(this, i);
    }

    size_t eraseHash(uint64_t h) {
        size_t i = slotFor(h);
        if (i == SIZE_MAX) return 0;
        state_[i] = kDeleted;
        size_--;
        return 1;
    }

    uint32_t& valueFor(uint64_t h) {
        size_t i = slotFor(h);
        if (i != SIZE_MAX) return slots_[i].second;
        if (slots_.empty() || (used_ + 1) * 4 > slots_.size() * 3) {
            // Grow when mostly live; otherwise rebuild in place to drop tombstones.
            rehash((size_ + 1) * 2 > slots_.size() / 2 ? capacityFor((size_ + 1) * 2)
                                                       : slots_.size());
        }
        size_t mask = slots_.size() - 1;
        i = static_cast<size_t>(h) & mask;
        while (state_[i] == kLive) i = (i + 1) & mask;
        if (state_[i] == kEmpty) used_++;
        state_[i] = kLive;
        slots_[i] = value_type{h, 0};
        size_++;
        return slots_[i].second;
    }

    void rehash(size_t newCap) {
        std::vector<value_type> oldSlots = std::move(slots_);
        std::vector<uint8_t> oldState = std::move(state_);
        slots_.assign(newCap, value_type{0, 0});
        state_.assign(newCap, kEmpty);
        size_ = 0;
        used_ = 0;
        size_t mask = newCap - 1;
        for (size_t j = 0; j < oldSlots.size(); j++) {
            if (oldState[j] != kLive) continue;
            size_t i = static_cast<size_t>(oldSlots[j].first) & mask;
            while (state_[i] != kEmpty) i = (i + 1) & mask;
            state_[i] = kLive;
            slots_[i] = oldSlots[j];
            size_++;
            used_++;
        }
    }

    std::vector<value_type> slots_;
    std::vector<uint8_t> state_;
    size_t size_ = 0;   // live entries
    size_t used_ = 0;   // live + tombstoned slots
};
